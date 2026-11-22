// Exercise the real page's chooser wiring, rather than only the chooser's
// cancellation policy. No Android engine is needed for the widget lifecycle.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/plugins/islands/island_platform.dart';
import 'package:dsh_app/ui/web/web_file_chooser.dart';
import 'package:dsh_app/ui/web/web_view_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../chat/support/harness.dart';
import 'support/fake_webview.dart';

const _channel = MethodChannel('dsh/web-files');
const _file = 'content://documents/document/picked';
const _params = FileSelectorParams(isCaptureEnabled: false, acceptTypes: [], mode: FileSelectorMode.open);
const _big = 'content://downloads/document/big';

Map<String, Object?> _pick({List<String> uris = const [], List<Map<String, Object?>> rejected = const []}) =>
    {'uris': uris, 'rejected': rejected};
Map<String, Object?> _oversize({int bytes = 33 * 1024 * 1024}) =>
    {'uri': _big, 'name': 'big.bin', 'bytes': bytes};

class _AndroidPlatform extends FakeWebViewPlatform {
  @override
  _AndroidController get controller => controllers.single as _AndroidController;

  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) {
    final controller = _AndroidController(params);
    controllers.add(controller);
    return controller;
  }
}

class _AndroidController extends FakeWebViewController implements AndroidWebViewController {
  _AndroidController(super.params);

  Future<List<String>> Function(FileSelectorParams)? selector;

  @override
  Future<void> setOnShowFileSelector(Future<List<String>> Function(FileSelectorParams)? callback) async {
    calls.add('setOnShowFileSelector');
    selector = callback;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _AndroidPlatform web;
  late FakeIslandPlatform islands;
  late IslandPlatform original;
  late List<MethodCall> calls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WebKeyboard.forgetHeights();
    WebViewPlatform.instance = web = _AndroidPlatform();
    original = IslandPlatform.instance;
    IslandPlatform.instance = islands = FakeIslandPlatform();
    calls = [];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return call.method == 'pick' ? _pick(uris: const [_file]) : null;
    });
  });
  tearDown(() {
    IslandPlatform.instance = original;
    messenger.setMockMethodCallHandler(_channel, null);
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    Future<void> Function(List<WebStagedFile> staged, List<WebFileOversize> refused)? onOversize,
  }) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(WebViewPage(url: Uri.parse('http://127.0.0.1:3080/'), title: '网页', dshWeb: true, onOversize: onOversize)),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(web.controller.selector, isNotNull);
    expect(
      web.controller.calls.indexOf('setOnShowFileSelector'),
      lessThan(web.controller.calls.indexOf('loadRequest')),
    );
    web.controller.finish();
    await tester.pump();
  }

  testWidgets('opening and closing the keyboard does not dispose the upload callback', (tester) async {
    await pumpPage(tester);
    expect(await web.controller.selector!(_params), [_file]);
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    await tester.pump();
    await tester.pump(WebKeyboard.rest);
    expect(await web.controller.selector!(_params), [_file]);
    tester.view.resetViewInsets();
    await tester.pump();
    await tester.pump(WebKeyboard.rest);
    expect(await web.controller.selector!(_params), [_file]);
    expect(calls.where((c) => c.method == 'pick'), hasLength(3));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final rendererGone in [false, true]) {
    testWidgets('page disposal/renderer loss cancels its pending selection: renderer=$rendererGone', (tester) async {
      await pumpPage(tester);
      final selected = Completer<Object?>();
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return call.method == 'pick' ? selected.future : null;
      });
      final pending = web.controller.selector!(_params);
      await tester.pump();
      expect(calls.where((c) => c.method == 'pick'), hasLength(1));
      if (rendererGone) {
        islands.gone();
        await tester.pump();
      } else {
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.pump();
      expect(calls.where((c) => c.method == 'cancel'), hasLength(1));
      selected.complete(_pick(uris: const [_file]));
      expect(await pending, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('a file over the ceiling is said out loud instead of silently dropped', (tester) async {
    await pumpPage(tester);
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return call.method == 'pick' ? _pick(rejected: [_oversize()]) : null;
    });
    expect(await web.controller.selector!(_params), isEmpty);
    await tester.pump();
    expect(find.widgetWithText(SnackBar, appL10n.webAttachmentTooLarge), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an oversized pick is staged for the app and the page carries nothing', (tester) async {
    final staged = Completer<List<WebStagedFile>>();
    final refused = Completer<List<WebFileOversize>>();
    await pumpPage(
      tester,
      onOversize: (files, cannotRead) async {
        staged.complete(files);
        refused.complete(cannotRead);
      },
    );
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'pick' => _pick(rejected: [_oversize()]),
        'stage' => {'path': '/data/cache/web-files/1/big.bin', 'name': 'big.bin', 'bytes': 3},
        _ => null,
      };
    });
    expect(await web.controller.selector!(_params), isEmpty);
    for (var i = 0; i < 100 && !staged.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    final copies = await staged.future;
    expect(copies.single.name, 'big.bin');
    expect(copies.single.bytes, 3);
    expect(await refused.future, isEmpty);
    expect(calls.where((c) => c.method == 'stage'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
