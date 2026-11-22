import 'dart:async';
import 'dart:io';

import 'package:dsh_app/ui/web/web_file_chooser.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

const _channel = MethodChannel('test/web-files');
const _url = 'http://127.0.0.1:3080/?token=test-only';
const _file = 'content://com.android.providers.media.documents/document/image:12';
const _big = 'content://com.android.providers.downloads.documents/document/77';

Map<String, Object?> _pick({List<String> uris = const [], List<Map<String, Object?>> rejected = const []}) =>
    {'uris': uris, 'rejected': rejected};

Map<String, Object?> _oversize({String uri = _big, String name = 'handoff.tar.gz', int bytes = 86928832}) =>
    {'uri': uri, 'name': name, 'bytes': bytes};

FileSelectorParams _params({FileSelectorMode mode = FileSelectorMode.open, List<String> accept = const []}) =>
    FileSelectorParams(isCaptureEnabled: false, acceptTypes: accept, mode: mode);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late WebFileChooser chooser;
  late List<MethodCall> calls;
  late String? url;

  Future<List<String>> choose([FileSelectorParams? params]) =>
      chooser.choose(params ?? _params(), webViewId: 7, currentUrl: () async => url);

  setUp(() {
    calls = [];
    url = _url;
    chooser = WebFileChooser(channel: _channel);
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return call.method == 'pick' ? _pick(uris: const [_file]) : null;
    });
  });
  tearDown(() {
    chooser.dispose();
    messenger.setMockMethodCallHandler(_channel, null);
  });

  test('selected content URI and MIME/multiple request reach the existing callback', () async {
    expect(await choose(_params(accept: ['image/*', 'application/pdf'], mode: FileSelectorMode.openMultiple)), [_file]);
    expect(calls.single.arguments, {
      'owner': '7:0',
      'webViewId': 7,
      'url': _url,
      'acceptTypes': ['image/*', 'application/pdf'],
      'multiple': true,
      // The renderer holds the whole file: the ceiling travels with the pick.
      'maxBytes': maxWebFileBytes,
    });
  });

  test('multiple files are returned only for an input that requests them', () async {
    messenger.setMockMethodCallHandler(_channel, (_) async => _pick(uris: const [_file, 'content://docs/document/2']));
    expect(await choose(), isEmpty);
    expect(await choose(_params(mode: FileSelectorMode.openMultiple)), hasLength(2));
  });

  for (final response in [
    null,
    <String, Object?>{},
    _pick(),
    _pick(uris: const ['file:///data/user/0/app/private']),
    _pick(uris: const ['content:///missing-authority']),
    // Not even the shape the plugin answers with.
    'not a selection',
    <int>[12],
  ]) {
    test('cancellation or unsupported URI produces an empty callback: $response', () async {
      messenger.setMockMethodCallHandler(_channel, (_) async => response);
      expect(await choose(), isEmpty);
    });
  }

  test('missing picker/platform error completes the callback and permits a retry', () async {
    messenger.setMockMethodCallHandler(_channel, (_) async => throw PlatformException(code: 'unavailable'));
    expect(await choose(), isEmpty);
    messenger.setMockMethodCallHandler(_channel, (_) async => _pick(uris: const [_file]));
    expect(await choose(), [_file]);
  });

  group('over the ceiling', () {
    late List<WebFileOversize> oversize;
    setUp(() {
      oversize = [];
      chooser = WebFileChooser(channel: _channel, onOversize: (files) async => oversize = files);
    });

    test('stays out of the page and is handed to the app instead', () async {
      messenger.setMockMethodCallHandler(
        _channel,
        (_) async => _pick(uris: const [_file], rejected: [_oversize()]),
      );
      expect(await choose(_params(mode: FileSelectorMode.openMultiple)), [_file]);
      await pumpEventQueue();
      expect(oversize, hasLength(1));
      expect(oversize.single.uri, _big);
      expect(oversize.single.name, 'handoff.tar.gz');
      expect(oversize.single.bytes, 86928832);
    });

    test('answers the page first: the pick never waits for the hand-over', () async {
      final handed = Completer<void>();
      chooser = WebFileChooser(channel: _channel, onOversize: (_) => handed.future);
      messenger.setMockMethodCallHandler(_channel, (_) async => _pick(rejected: [_oversize()]));
      expect(await choose(), isEmpty);
      expect(handed.isCompleted, isFalse);
      handed.complete();
      await pumpEventQueue();
    });

    test('without a handler the page simply gets nothing, and can pick again', () async {
      chooser = WebFileChooser(channel: _channel);
      messenger.setMockMethodCallHandler(_channel, (_) async => _pick(rejected: [_oversize()]));
      expect(await choose(), isEmpty);
      messenger.setMockMethodCallHandler(_channel, (_) async => _pick(uris: const [_file]));
      expect(await choose(), [_file]);
    });
  });

  test('a staged copy is thrown away with its folder', () async {
    final directory = await Directory.systemTemp.createTemp('dsh-web-files');
    final copy = File('${directory.path}/big.bin')..writeAsBytesSync(const [1, 2, 3]);
    await WebFileChooser.discard(WebStagedFile(path: copy.path, name: 'big.bin', bytes: 3));
    expect(directory.existsSync(), isFalse);
  });

  group('staging', () {
    const copy = {'path': '/data/cache/web-files/1/handoff.tar.gz', 'name': 'handoff.tar.gz', 'bytes': 86928832};

    test('returns the cache copy the platform made', () async {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return call.method == 'stage' ? copy : null;
      });
      final staged = await chooser.stage(const WebFileOversize(uri: _big, name: 'handoff.tar.gz', bytes: 86928832));
      expect(staged?.path, copy['path']);
      expect(staged?.name, 'handoff.tar.gz');
      expect(staged?.bytes, 86928832);
      expect(calls.single.arguments, {'uri': _big, 'name': 'handoff.tar.gz'});
    });

    test('an unreadable or refused copy is null, not a broken path', () async {
      messenger.setMockMethodCallHandler(_channel, (_) async => throw PlatformException(code: 'unreadable'));
      expect(await chooser.stage(const WebFileOversize(uri: _big, name: 'x', bytes: 1)), isNull);
      messenger.setMockMethodCallHandler(_channel, (_) async => {'path': '', 'name': 'x', 'bytes': 1});
      expect(await chooser.stage(const WebFileOversize(uri: _big, name: 'x', bytes: 1)), isNull);
    });
  });

  group('HarmonyOS', () {
    const docs = 'file://docs/storage/Users/currentUser/Download/a.pdf';
    const media = 'file://media/Photo/12/IMG_1/a.jpg';

    late WebFileChooser ohos;
    setUp(() => ohos = WebFileChooser(channel: _channel, ohos: true));
    tearDown(() => ohos.dispose());

    Future<List<String>> pick(List<String> response) {
      messenger.setMockMethodCallHandler(_channel, (call) async => _pick(uris: response));
      return ohos.choose(_params(mode: FileSelectorMode.openMultiple), webViewId: 7, currentUrl: () async => url);
    }

    test("the system picker's URIs reach the page", () async {
      expect(await pick(const [docs, media]), const [docs, media]);
    });

    test('the plain list this channel started with still reaches the page', () async {
      messenger.setMockMethodCallHandler(_channel, (_) async => const [docs, media]);
      expect(
        await ohos.choose(_params(mode: FileSelectorMode.openMultiple), webViewId: 7, currentUrl: () async => url),
        const [docs, media],
      );
    });

    for (final bad in [
      'file:///data/storage/el2/base/haps/entry/files/secret',
      'file://com.example.app/data/storage/el2/base/files/secret',
      '/data/storage/el2/base/files/secret',
      _file,
    ]) {
      test('$bad is refused, along with the rest of the pick', () async {
        expect(await pick([docs, bad]), isEmpty);
      });
    }
  });

  test('save mode and non-web documents never invoke a file picker', () async {
    expect(await choose(_params(mode: FileSelectorMode.save)), isEmpty);
    url = 'file:///data/user/0/app/page.html';
    expect(await choose(), isEmpty);
    expect(calls, isEmpty);
  });

  test('a second callback cannot steal the outstanding picker result', () async {
    final selected = Completer<Object?>();
    messenger.setMockMethodCallHandler(_channel, (call) {
      calls.add(call);
      return selected.future;
    });
    final first = choose();
    await pumpEventQueue();
    expect(await choose(), isEmpty);
    expect(calls, hasLength(1));
    selected.complete(_pick(uris: const [_file]));
    expect(await first, [_file]);
  });

  for (final dispose in [false, true]) {
    test('navigation/disposal retires a late Android result (dispose=$dispose)', () async {
      final selected = Completer<Object?>();
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return call.method == 'pick' ? selected.future : null;
      });
      final pending = choose();
      await pumpEventQueue();
      if (dispose) {
        chooser.dispose();
      } else {
        chooser.invalidate();
      }
      await pumpEventQueue();
      expect(calls.last.method, 'cancel');
      expect(calls.last.arguments, {'owner': '7:0'});
      selected.complete(_pick(uris: const [_file]));
      expect(await pending, isEmpty);
    });
  }

  test('URL changed while selecting does not receive the selected file', () async {
    messenger.setMockMethodCallHandler(_channel, (_) async {
      url = 'https://other.example/';
      return _pick(uris: const [_file]);
    });
    expect(await choose(), isEmpty);
  });

  test('same-URL reload during the final URL lookup still retires the callback', () async {
    var reads = 0;
    final finalUrl = Completer<String>();
    final pending = chooser.choose(
      _params(),
      webViewId: 7,
      currentUrl: () async => ++reads == 1 ? _url : finalUrl.future,
    );
    await pumpEventQueue();
    chooser.invalidate();
    finalUrl.complete(_url);
    expect(await pending, isEmpty);
  });
}
