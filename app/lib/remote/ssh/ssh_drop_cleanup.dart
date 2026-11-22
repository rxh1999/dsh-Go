import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

typedef SshDropScope = ({String hostId, String fingerprint, String user});
typedef SshPartialDrop = ({SshDropScope scope, String folder, String stagingName});

/// Records app-owned partial files before they can exist on the remote. The
/// app shares one store across links so a connection cannot clean another's
/// in-flight transfer. A new process loads abandoned records from app support.
class SshDropCleanup {
  SshDropCleanup([this._loadDirectory]);

  static const remoteRoot = '.dsh-go-uploads';
  static const stagingNames = {'.partial', '.partial-file'};
  static final _recordName = RegExp(r'^\d+-[0-9a-f]+-\d+\.json$');

  final Future<Directory> Function()? _loadDirectory;
  final _active = <SshPartialDrop>{};
  final _memory = <SshPartialDrop>{};
  final _released = StreamController<SshPartialDrop>.broadcast();

  Stream<SshPartialDrop> get released => _released.stream;

  Future<void> start(SshPartialDrop drop) async {
    _active.add(drop);
    try {
      final marker = await _marker(drop);
      if (marker != null) {
        await marker.parent.create(recursive: true);
        final temporary = File('${marker.path}.tmp');
        await temporary.writeAsString(jsonEncode([drop.folder, drop.stagingName]), flush: true);
        await temporary.rename(marker.path);
      } else {
        _memory.add(drop);
      }
    } catch (_) {
      _active.remove(drop);
      rethrow;
    }
  }

  void release(SshPartialDrop drop) {
    _active.remove(drop);
    _released.add(drop);
  }

  Future<void> forget(SshPartialDrop drop) async {
    try {
      final marker = await _marker(drop);
      if (marker != null && await marker.exists()) await marker.delete();
      _memory.remove(drop);
    } finally {
      _active.remove(drop);
    }
  }

  Future<List<SshPartialDrop>> pending(SshDropScope scope) async {
    final directory = await _directory(scope);
    if (directory == null) {
      return [
        for (final drop in _memory)
          if (drop.scope == scope && !_active.contains(drop)) drop,
      ];
    }
    if (!await directory.exists()) return [];
    final drops = <SshPartialDrop>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File || !_recordName.hasMatch(entry.uri.pathSegments.last)) continue;
      try {
        final data = jsonDecode(await entry.readAsString());
        final id = entry.uri.pathSegments.last.split('.').first;
        if (data case [final String folder, final String name]
            when folder.startsWith('/') &&
                folder.endsWith('/$remoteRoot/$id') &&
                !folder.contains('\u0000') &&
                stagingNames.contains(name)) {
          final drop = (scope: scope, folder: folder, stagingName: name);
          if (!_active.contains(drop)) drops.add(drop);
        }
      } on FormatException {
        // Only our own well-formed, generated staging paths may be deleted.
      } on FileSystemException {
        // A different link may already have cleared this marker.
      }
    }
    return drops;
  }

  Future<Directory?> _directory(SshDropScope scope) async {
    final loader = _loadDirectory;
    if (loader == null) return null;
    final root = await loader();
    final host = sha256.convert(utf8.encode(jsonEncode([scope.hostId, scope.fingerprint, scope.user])));
    return Directory('${root.path}/$host');
  }

  Future<File?> _marker(SshPartialDrop drop) async {
    final directory = await _directory(drop.scope);
    return directory == null ? null : File('${directory.path}/${drop.folder.split('/').last}.json');
  }
}
