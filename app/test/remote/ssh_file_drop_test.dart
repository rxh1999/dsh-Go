// A file the page cannot carry goes over the SSH link itself: SshHostLink's
// dropFile writes it through SshTransport.writeFile, under the link's working
// directory, one folder per drop.

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/ssh/ssh_drop_cleanup.dart';
import 'package:dsh_app/remote/ssh/ssh_host_config.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ssh.dart';

void main() {
  late FakeSshServer server;
  late FakeConnector connector;
  final links = <SshHostLink>[];

  setUp(() {
    server = FakeSshServer();
    connector = FakeConnector();
  });
  tearDown(() async {
    for (final link in links) {
      await link.close();
    }
    links.clear();
  });

  SshHostLink connect({String? workingDirectory = '~', SshDropCleanup? dropCleanup, Backoff? backoff}) {
    final link = SshHostLink(
      config: sampleSsh.copyWith(workingDirectory: () => workingDirectory),
      loadSecrets: () async => const SshSecrets(password: 'pw'),
      transportFactory: server.connect,
      connectClient: connector.call,
      dropCleanup: dropCleanup,
      backoff: backoff ?? Backoff(initial: const Duration(milliseconds: 20)),
      retryFirstOpen: false,
      keepAliveInterval: const Duration(minutes: 1),
    );
    links.add(link);
    return link;
  }

  Future<void> waitFor(FutureOr<bool> Function() predicate) async {
    for (var attempts = 0; attempts < 100; attempts++) {
      if (await predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Expected the remote cleanup to finish');
  }

  test('a dropped file lands under the working directory and keeps its name', () async {
    final link = connect();
    await link.open();
    final path = await link.dropFile('report.pdf', Stream.value([1, 2, 3]));
    expect(path, startsWith('/home/me/.dsh-go-uploads/'));
    expect(path, endsWith('/report.pdf'));
    expect(server.remote.files[path], [1, 2, 3]);
    expect(server.last.scripts.last, contains("mkdir -m 700 '/home/me/.dsh-go-uploads/"));
  });

  test('each drop gets a folder of its own', () async {
    final link = connect();
    await link.open();
    final [first, second] = await Future.wait([
      link.dropFile('a.txt', Stream.value([1])),
      link.dropFile('b.txt', Stream.value([2])),
    ]);
    expect(first, isNot(second));
    expect(first, endsWith('/a.txt'));
    expect(second, endsWith('/b.txt'));
    expect(server.remote.files, hasLength(2));
  });

  test('no configured working directory drops into the home directory', () async {
    final link = connect(workingDirectory: null);
    await link.open();
    final path = await link.dropFile('handoff.tar.gz', Stream.value([0]));
    expect(path, startsWith('/home/me/.dsh-go-uploads/'));
    expect(path, endsWith('/handoff.tar.gz'));
  });

  test('a name from another app stays one path component', () async {
    final link = connect();
    await link.open();
    final path = await link.dropFile('../../etc/passwd', Stream.value([0]));
    expect(path, endsWith('/passwd'));
    expect(path, isNot(contains('..')));
    expect(server.remote.files.keys.single, path);
  });

  test('a link that is not connected refuses instead of writing', () async {
    final link = connect();
    await expectLater(link.dropFile('a.txt', Stream.value([1])), throwsA(isA<HostLinkError>()));
    expect(server.remote.files, isEmpty);
  });

  test('an incomplete upload has only a temporary name and is removed after reconnect', () async {
    final link = connect();
    await link.open();
    final lost = server.last;
    final reconnected = link.statuses.firstWhere((status) => status.isConnected);
    Stream<List<int>> interrupted() async* {
      yield [1, 2, 3];
      expect(server.remote.files.keys.single, endsWith('/.partial'));
      expect(server.remote.files.values.single, [1, 2, 3]);
      lost.drop();
      yield [4];
    }

    await expectLater(link.dropFile('archive.tar.gz', interrupted()), throwsA(isA<HostLinkError>()));
    expect(server.remote.files.keys.single, endsWith('/.partial'));
    await reconnected;
    await waitFor(() => server.remote.files.isEmpty);
    expect(server.last, isNot(same(lost)));
    expect(server.remote.files, isEmpty);
    expect(server.last.scripts, contains(contains("/.partial' && (rmdir")));
  });

  test('cleanup preserves a completed file when the rename reply is lost', () async {
    final link = connect();
    await link.open();
    final lost = server.last;
    lost.afterRename = lost.drop;
    final reconnected = link.statuses.firstWhere((status) => status.isConnected);

    await expectLater(link.dropFile('.partial', Stream.value([1, 2, 3])), throwsA(isA<HostLinkError>()));
    await reconnected;
    await waitFor(() => server.last.scripts.any((script) => script.contains("/.partial-file' && (rmdir")));
    expect(server.last.scripts, contains(contains("/.partial-file' && (rmdir")));
    expect(server.remote.files.keys.single, endsWith('/.partial'));
    expect(server.remote.files.values.single, [1, 2, 3]);
  });

  test('reconnecting with a different host key cannot clean the old host staging file', () async {
    final link = connect();
    await link.open();
    final originalKey = server.hostKey;
    const replacementKey = PresentedHostKey('ssh-ed25519', 'SHA256:other');
    final lost = server.last;
    final reconnected = link.statuses.firstWhere((status) => status.isConnected);
    Stream<List<int>> interrupted() async* {
      yield [1, 2, 3];
      server.hostKey = replacementKey;
      link.updateConfig(link.config.copyWith(hostKeyFingerprint: () => replacementKey.fingerprint));
      lost.drop();
    }

    await expectLater(link.dropFile('archive.tar.gz', interrupted()), throwsA(isA<HostLinkError>()));
    await reconnected;
    expect(server.remote.files.keys.single, endsWith('/.partial'));
    expect(server.last.scripts, isNot(contains(contains("/.partial' && (rmdir"))));

    server.hostKey = originalKey;
    link.updateConfig(link.config.copyWith(hostKeyFingerprint: () => originalKey.fingerprint));
    final originalReconnected = link.statuses.firstWhere((status) => status.isConnected);
    server.last.drop();
    await originalReconnected;
    await waitFor(() => server.remote.files.isEmpty);
    expect(server.remote.files, isEmpty);
  });

  test('a new store and link recover remote staging left by the previous link', () async {
    final directory = await Directory.systemTemp.createTemp('dsh-ssh-drop-markers-');
    addTearDown(() => directory.delete(recursive: true));
    final firstStore = SshDropCleanup(() async => directory);
    final first = connect(
      dropCleanup: firstStore,
      backoff: Backoff(initial: const Duration(seconds: 5)),
    );
    await first.open();
    final lost = server.last;
    final scope = (hostId: sampleSsh.id, fingerprint: server.hostKey.fingerprint, user: sampleSsh.user);
    Stream<List<int>> interrupted() async* {
      yield [1, 2, 3];
      lost.drop();
    }

    await expectLater(first.dropFile('archive.tar.gz', interrupted()), throwsA(isA<HostLinkError>()));
    await first.close();
    expect(await firstStore.pending(scope), hasLength(1));
    expect(server.remote.files.keys.single, endsWith('/.partial'));

    final secondStore = SshDropCleanup(() async => directory);
    final second = connect(dropCleanup: secondStore);
    await second.open();
    await waitFor(() => server.remote.files.isEmpty);
    await waitFor(() async => (await secondStore.pending(scope)).isEmpty);
  });

  test('a second connection cannot clean an active drop until its original link releases it', () async {
    final directory = await Directory.systemTemp.createTemp('dsh-ssh-active-drop-');
    addTearDown(() => directory.delete(recursive: true));
    final cleanup = SshDropCleanup(() async => directory);
    final first = connect(
      dropCleanup: cleanup,
      backoff: Backoff(initial: const Duration(seconds: 5)),
    );
    await first.open();
    final lost = server.last;
    final data = StreamController<List<int>>();
    addTearDown(data.close);
    final drop = first.dropFile('archive.tar.gz', data.stream);
    final failed = expectLater(drop, throwsA(isA<HostLinkError>()));
    data.add([1, 2, 3]);
    await waitFor(() => server.remote.files.values.singleOrNull?.length == 3);

    final second = connect(dropCleanup: cleanup);
    await second.open();
    final scope = (hostId: sampleSsh.id, fingerprint: server.hostKey.fingerprint, user: sampleSsh.user);
    expect(await cleanup.pending(scope), isEmpty);
    expect(server.remote.files.keys.single, endsWith('/.partial'));

    lost.drop();
    data.add([4]);
    await data.close();
    await failed;
    await waitFor(() => server.remote.files.isEmpty);
    await waitFor(() async => (await cleanup.pending(scope)).isEmpty);
  });
}
