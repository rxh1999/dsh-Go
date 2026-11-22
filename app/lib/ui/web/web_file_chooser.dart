import 'dart:async';
import 'dart:io' show File, FileSystemException, Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Most a picked file may be for the page to carry it.
///
/// The page reads a chosen file into its own renderer process as a Blob, so the
/// whole file has to fit there. One big enough to exhaust that process does not
/// just fail the upload: Android kills the renderer, `onRenderProcessGone`
/// fires, and the app tears the page down — with the conversation draft in it.
/// Larger files are handed over by the app instead (`WebViewPage.onOversize`).
const maxWebFileBytes = 32 * 1024 * 1024;

/// One picked file the page must not carry, with the size the platform saw.
class WebFileOversize {
  const WebFileOversize({required this.uri, required this.name, required this.bytes});

  final String uri;
  final String name;

  /// The provider's declared size; 0 when it declared none.
  final int bytes;
}

/// A cache copy of an oversized pick, for the app to give to the Host.
class WebStagedFile {
  const WebStagedFile({required this.path, required this.name, required this.bytes});

  final String path;
  final String name;
  final int bytes;
}

/// What one picker callback produced.
class WebFilePick {
  const WebFilePick({this.uris = const [], this.oversize = const []});

  /// The files whose content URIs the page may carry.
  final List<String> uris;

  /// The files it may not, over [maxWebFileBytes].
  final List<WebFileOversize> oversize;
}

/// A document chooser belongs to the document that requested it. Navigation,
/// a renderer loss or disposal retires it even if Android returns a file later.
/// The platform returns temporary content URIs (on HarmonyOS the system
/// picker's `file://docs/…` and `file://media/…`), without copying file contents
/// into Dart or granting the page access to app-private filesystem paths.
class WebFileChooser {
  WebFileChooser({MethodChannel? channel, bool? ohos, this._canChoose, this.onOversize})
    : _channel = channel ?? const MethodChannel('dsh/web-files'),
      _ohos = ohos ?? Platform.operatingSystem == 'ohos';

  final MethodChannel _channel;
  final bool _ohos;
  final bool Function()? _canChoose;

  /// Called once the page has been given its answer, with the picks it may not
  /// carry: whoever handles them runs after the file input is done with.
  final Future<void> Function(List<WebFileOversize> files)? onOversize;

  int _generation = 0;
  bool _disposed = false;
  bool _busy = false;
  String? _owner;

  Future<void> attach(WebViewController controller) async {
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      await platform.setOnShowFileSelector(
        (params) => choose(params, webViewId: platform.webViewIdentifier, currentUrl: controller.currentUrl),
      );
    } else if (_ohos) {
      // oh-flutter's controller has the same method and fields, but its package
      // is only in the HarmonyOS build.
      final dynamic ohos = platform;
      await ohos.setOnShowFileSelector(
        (dynamic params) => choose(
          FileSelectorParams(
            isCaptureEnabled: params.isCaptureEnabled as bool,
            acceptTypes: List<String>.from(params.acceptTypes as List),
            filenameHint: params.filenameHint as String?,
            mode: FileSelectorMode.values.byName((params.mode as Enum).name),
          ),
          webViewId: ohos.webViewIdentifier as int,
          currentUrl: controller.currentUrl,
        ),
      );
    }
  }

  @visibleForTesting
  Future<List<String>> choose(
    FileSelectorParams params, {
    required int webViewId,
    required Future<String?> Function() currentUrl,
  }) async {
    // A file upload never creates/overwrites a local file. Capture is a hint:
    // use the system document UI without silently acquiring camera/mic access.
    if (_disposed || _busy || _canChoose?.call() == false || params.mode == FileSelectorMode.save) return const [];
    _busy = true;
    final generation = _generation;
    final owner = '$webViewId:$generation';
    bool current() => !_disposed && generation == _generation && _canChoose?.call() != false;
    try {
      final url = await currentUrl();
      final uri = Uri.tryParse(url ?? '');
      if (!current() || uri == null || !['http', 'https'].contains(uri.scheme)) {
        return const [];
      }
      _owner = owner;
      final pick = _parse(
        await _channel.invokeMethod<Object?>('pick', {
          'owner': owner,
          'webViewId': webViewId,
          'url': url,
          'acceptTypes': params.acceptTypes,
          'multiple': params.mode == FileSelectorMode.openMultiple,
          'maxBytes': maxWebFileBytes,
        }),
      );
      if (!current()) return const [];
      final after = await currentUrl();
      if (!current() || after != url) return const [];
      // Native also validates grants/providers. Never hand an app-private path
      // or a malformed plugin response to the WebView.
      if (!pick.uris.every(_grantedUri)) return const [];
      if (params.mode == FileSelectorMode.open && pick.uris.length > 1) return const [];
      // The page's input is answered from here: a file it cannot hold is the
      // app's problem, and the answer must not wait for it.
      final handler = onOversize;
      if (pick.oversize.isNotEmpty && handler != null) unawaited(handler(pick.oversize));
      return pick.uris;
    } on Object {
      // The WebChromeClient must always receive an answer, including when a
      // renderer/platform disappears while either URL or chooser is pending.
      return const [];
    } finally {
      if (_owner == owner) _owner = null;
      _busy = false;
    }
  }

  /// Copies an oversized pick into the app cache — streamed by the platform,
  /// never through Dart's heap — so the app can give the bytes to a Host.
  /// Null when the file cannot be read.
  Future<WebStagedFile?> stage(WebFileOversize file) async {
    try {
      final staged = await _channel.invokeMapMethod<String, Object?>('stage', {'uri': file.uri, 'name': file.name});
      final path = staged?['path'];
      final name = staged?['name'];
      final bytes = staged?['bytes'];
      if (path is! String || path.isEmpty || name is! String || bytes is! int) return null;
      return WebStagedFile(path: path, name: name, bytes: bytes);
    } on Object {
      return null;
    }
  }

  /// Removes a [stage]d copy. Android reclaims its own cache, so a failure
  /// here costs disk until then and nothing else.
  static Future<void> discard(WebStagedFile staged) async {
    try {
      await File(staged.path).parent.delete(recursive: true);
    } on FileSystemException {
      // Already gone, or not ours to delete.
    }
  }

  WebFilePick _parse(Object? response) {
    // The HarmonyOS host answers with the plain list this channel started
    // with: no ceiling there yet, and nothing else changes for it.
    if (response is List) return WebFilePick(uris: response.whereType<String>().toList(growable: false));
    if (response is! Map) return const WebFilePick();
    final uris = response['uris'];
    final rejected = response['rejected'];
    return WebFilePick(
      uris: uris is List ? uris.whereType<String>().toList(growable: false) : const [],
      oversize: rejected is List
          ? [
              for (final item in rejected)
                if (item is Map && item['uri'] is String && (item['uri'] as String).isNotEmpty)
                  WebFileOversize(
                    uri: item['uri'] as String,
                    name: item['name'] is String ? item['name'] as String : '',
                    bytes: item['bytes'] is int ? item['bytes'] as int : 0,
                  ),
            ]
          : const [],
    );
  }

  bool _grantedUri(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return false;
    if (_ohos) return uri.scheme == 'file' && const {'docs', 'media'}.contains(uri.authority);
    return uri.scheme == 'content' && uri.authority.isNotEmpty;
  }

  void invalidate() {
    _generation++;
    final owner = _owner;
    _owner = null;
    if (owner != null) {
      unawaited(_channel.invokeMethod<void>('cancel', {'owner': owner}).catchError((Object _) {}));
    }
  }

  void dispose() {
    _disposed = true;
    invalidate();
  }
}
