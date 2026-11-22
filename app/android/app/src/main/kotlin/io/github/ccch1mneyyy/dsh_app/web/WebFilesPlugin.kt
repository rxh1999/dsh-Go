package io.github.ccch1mneyyy.dsh_app.web

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import android.webkit.WebView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi
import io.github.ccch1mneyyy.dsh_app.MainActivity
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executors

/**
 * A foreground web upload: system-selected content URIs, no persistent grant.
 *
 * Files above the caller's byte ceiling or with unknown sizes are returned
 * under `rejected` with their URI, name, and nullable size. The app can use
 * `stage` to stream these files into its cache for Host delivery.
 */
class WebFilesPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {
    private data class Pending(
        val owner: String, val view: WebView, val url: String,
        val multiple: Boolean, val maxBytes: Long, val result: MethodChannel.Result,
    )

    /** One content URI's declared metadata, as the provider answered. */
    private class Measured(val name: String?, val bytes: Long?)

    /** A staging copy that cannot be handed over, with a stable code. */
    private class StageFailure(val code: String) : Exception(code)

    private var engine: FlutterPlugin.FlutterPluginBinding? = null
    private var activity: ActivityPluginBinding? = null
    private var channel: MethodChannel? = null
    private var pending: Pending? = null
    // Cancelling the owner does not dismiss the system picker. Do not let a
    // late result satisfy a new request with the same Activity request code.
    private var waiting = false
    // A measurement or copy outlives an engine (an app update, a host switch).
    private var detached = false
    private val main = Handler(Looper.getMainLooper())
    // Measuring and copying are provider reads: never on the main thread.
    private val worker = Executors.newFixedThreadPool(2)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        engine = binding
        detached = false
        channel = MethodChannel(binding.binaryMessenger, "dsh/web-files").also { it.setMethodCallHandler(this) }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        cancel()
        detached = true
        channel?.setMethodCallHandler(null)
        channel = null
        engine = null
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addActivityResultListener(this)
    }
    override fun onDetachedFromActivityForConfigChanges() {
        cancel()
        activity?.removeActivityResultListener(this)
        activity = null
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        waiting = false
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> pick(call, result)
            "cancel" -> {
                if (call.argument<String>("owner") == pending?.owner) cancel()
                result.success(null)
            }
            "stage" -> stage(call, result)
            else -> result.notImplemented()
        }
    }

    private fun pick(call: MethodCall, result: MethodChannel.Result) {
        val binding = engine
        val activity = activity?.activity
        val id = (call.argument<Any>("webViewId") as? Number)?.toLong()
        val view = if (binding != null && id != null)
            runCatching { WebViewFlutterAndroidExternalApi.getWebView(binding, id) }.getOrNull() else null
        val owner = call.argument<String>("owner")
        val url = call.argument<String>("url")
        val maxBytes = (call.argument<Any>("maxBytes") as? Number)?.toLong() ?: 0L
        if (waiting || pending != null || activity == null || !MainActivity.inForeground ||
            view == null || !view.isShown || owner.isNullOrEmpty() || url.isNullOrEmpty() || view.url != url ||
            maxBytes < 1 || maxBytes > WebFilePolicy.HARD_MAX_BYTES) {
            result.success(noSelection()); return
        }
        val types = WebFilePolicy.acceptTypes(call.argument<List<String>>("acceptTypes") ?: emptyList()) {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(it)
        }
        val multiple = call.argument<Boolean>("multiple") == true
        val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = types.singleOrNull() ?: "*/*"
            if (types.size > 1) putExtra(Intent.EXTRA_MIME_TYPES, types.toTypedArray())
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        pending = Pending(owner, view, url, multiple, maxBytes, result)
        waiting = true
        try {
            activity.startActivityForResult(intent, REQUEST)
        } catch (_: Exception) {
            waiting = false
            cancel()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST) return false
        waiting = false
        val request = pending ?: return true
        pending = null
        val context = engine?.applicationContext
        if (resultCode != Activity.RESULT_OK || data == null || context == null ||
            request.view.url != request.url || !request.view.isAttachedToWindow) {
            request.result.success(noSelection()); return true
        }
        val uris = data.clipData?.let { clip -> (0 until clip.itemCount).map { clip.getItemAt(it).uri } }
            ?: listOfNotNull(data.data)
        val allowed = uris.isNotEmpty() && (request.multiple || uris.size == 1) && uris.all { uri ->
            uri != null && WebFilePolicy.isExternalContent(uri.toString(), context.packageName) &&
                context.packageManager.resolveContentProvider(uri.authority ?: "", 0)?.applicationInfo?.uid != Process.myUid() &&
                context.checkUriPermission(uri, Process.myPid(), Process.myUid(), Intent.FLAG_GRANT_READ_URI_PERMISSION) ==
                    PackageManager.PERMISSION_GRANTED
        }
        if (!allowed) {
            request.result.success(noSelection()); return true
        }
        val picked = uris.filterNotNull().map { it.toString() }.distinct()
        worker.execute {
            // Measuring reads the provider: off the main thread, so a slow one
            // cannot freeze the page it is measuring for.
            val selection = select(context, picked, request.maxBytes)
            main.post { if (!detached) request.result.success(selection) }
        }
        return true
    }

    /** Splits one pick into what the page may carry and what it may not. */
    private fun select(context: Context, picked: List<String>, maxBytes: Long): Map<String, Any?> {
        val kept = mutableListOf<String>()
        val rejected = mutableListOf<Map<String, Any?>>()
        for (raw in picked) {
            val measured = runCatching { measure(context, Uri.parse(raw)) }.getOrDefault(Measured(null, null))
            if (WebFilePolicy.withinLimit(measured.bytes, maxBytes)) {
                kept.add(raw)
            } else {
                rejected.add(mapOf("uri" to raw, "name" to measured.name, "bytes" to measured.bytes))
            }
        }
        return mapOf("uris" to kept, "rejected" to rejected)
    }

    /** The name and size the provider declares; null for what it does not. */
    private fun measure(context: Context, uri: Uri): Measured {
        var name: String? = null
        var size: Long? = null
        try {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (nameColumn >= 0 && !cursor.isNull(nameColumn)) name = cursor.getString(nameColumn)
                        val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) size = cursor.getLong(sizeColumn)
                    }
                }
        } catch (_: Exception) {
            // Some providers answer only openAssetFileDescriptor.
        }
        val declared = size
        val descriptor = if (declared == null || declared <= 0) {
            try {
                context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length }
            } catch (_: Exception) {
                null
            }
        } else {
            null
        }
        return Measured(name, WebFilePolicy.declaredBytes(size, descriptor))
    }

    /**
     * Copies [uri] into the app cache and answers `{path, name, bytes}`, so the
     * app can give the bytes to a Host without the page ever holding them.
     * Streams: the copy never sits in memory.
     */
    private fun stage(call: MethodCall, result: MethodChannel.Result) {
        val context = engine?.applicationContext
        val raw = call.argument<String>("uri")
        if (context == null || raw.isNullOrEmpty() || !WebFilePolicy.isExternalContent(raw, context.packageName)) {
            result.error("unavailable", "nothing to stage", null); return
        }
        val name = WebFilePolicy.stagedName(call.argument<String>("name"))
        worker.execute {
            val staged = try {
                copyToCache(context, Uri.parse(raw), name)
            } catch (e: StageFailure) {
                main.post { if (!detached) result.error(e.code, "the file could not be staged", null) }
                return@execute
            } catch (_: Exception) {
                main.post { if (!detached) result.error("unreadable", "the file could not be staged", null) }
                return@execute
            }
            main.post { if (!detached) result.success(staged) }
        }
    }

    private fun copyToCache(context: Context, uri: Uri, name: String): Map<String, Any?> {
        val directory = File(context.cacheDir, "web-files/${UUID.randomUUID()}")
        if (!directory.mkdirs()) throw StageFailure("unavailable")
        val target = File(directory, name)
        val input = try {
            context.contentResolver.openInputStream(uri)
        } catch (_: Exception) {
            null
        } ?: run {
            directory.delete()
            throw StageFailure("unreadable")
        }
        var copied = 0L
        try {
            input.use { stream ->
                target.outputStream().use { out ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = stream.read(buffer)
                        if (read < 0) break
                        copied += read
                        if (copied > WebFilePolicy.HARD_MAX_BYTES) throw StageFailure("too_large")
                        out.write(buffer, 0, read)
                    }
                }
            }
        } catch (e: StageFailure) {
            directory.deleteRecursively()
            throw e
        } catch (_: IOException) {
            directory.deleteRecursively()
            throw StageFailure("unreadable")
        }
        return mapOf("path" to target.absolutePath, "name" to name, "bytes" to copied)
    }

    private fun cancel() {
        val request = pending
        pending = null
        request?.result?.success(noSelection())
    }

    private fun noSelection(): Map<String, Any?> = mapOf(
        "uris" to emptyList<String>(),
        "rejected" to emptyList<Map<String, Any?>>(),
    )

    companion object { private const val REQUEST = 0x6D57 }
}
