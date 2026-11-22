// A file the page cannot carry goes over the SSH link itself: SshHostLink's
// dropFile writes it through SshTransport.writeFile, under the link's working
// directory, one folder per drop.

import 'dart:async';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/ssh/ssh_host_config.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
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

  SshHostLink connect({String? workingDirectory = '~'}) {
    final link = SshHostLink(
      config: sampleSsh.copyWith(workingDirectory: () => workingDirectory),
      loadSecrets: () async => const SshSecrets(password: 'pw'),
      transportFactory: server.connect,
      connectClient: connector.call,
      retryFirstOpen: false,
      keepAliveInterval: const Duration(minutes: 1),
    );
    links.add(link);
    return link;
  }

  test('a dropped file lands under the working directory and keeps its name', () async {
    final link = connect();
    await link.open();
    final path = await link.dropFile('report.pdf', Stream.value([1, 2, 3]));
    expect(path, startsWith('/home/me/.dsh-go-uploads/'));
    expect(path, endsWith('/report.pdf'));
    expect(server.remote.files[path], [1, 2, 3]);
    // The folder is made first, and only that folder.
    expect(server.last.scripts.last, contains("mkdir -p '/home/me/.dsh-go-uploads/"));
  });

  test('each drop gets a folder of its own', () async {
    final link = connect();
    await link.open();
    final first = await link.dropFile('a.txt', Stream.value([1]));
    final second = await link.dropFile('b.txt', Stream.value([2]));
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
}
