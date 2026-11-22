package io.github.ccch1mneyyy.dsh_app.web

import java.net.URI
import java.util.Locale

/** Parsing only: no filesystem reads, grants or Android dependencies. */
internal object WebFilePolicy {
    private val mime = Regex("""^[a-z0-9!#$&^_.+-]+/([a-z0-9!#$&^_.+-]+|[*])$""")

    /**
     * The most one picker result may be over, however many files it holds. A
     * content URI can claim any length; this is the app's own ceiling on what
     * it is willing to copy into its cache for a Host.
     */
    const val HARD_MAX_BYTES = 2L * 1024 * 1024 * 1024

    fun acceptTypes(raw: List<String>, extensionType: (String) -> String?): List<String> {
        val types = raw.flatMap { it.split(',') }.mapNotNull {
            val value = it.trim().lowercase(Locale.ROOT)
            if (value.startsWith('.')) extensionType(value.drop(1)) else value
        }.filter { it == "*/*" || mime.matches(it) }.distinct()
        return if (types.isEmpty() || "*/*" in types) listOf("*/*") else types
    }

    fun isExternalContent(raw: String, appId: String): Boolean {
        val uri = runCatching { URI(raw) }.getOrNull() ?: return false
        val authority = uri.authority ?: return false
        return uri.scheme == "content" && authority.isNotEmpty() &&
            authority != appId && !authority.startsWith(appId + ".")
    }

    /**
     * The size a provider declares for one picked file, or null when it
     * declares nothing usable.
     *
     * `OpenableColumns.SIZE` answers for most providers. A non-positive value
     * is not a size: several return 0 or -1 for documents they stream, so the
     * descriptor's length is tried next, and `AssetFileDescriptor` uses -1 for
     * "unknown" too.
     */
    fun declaredBytes(sizeColumn: Long?, descriptorLength: Long?): Long? {
        if (sizeColumn != null && sizeColumn > 0) return sizeColumn
        if (descriptorLength != null && descriptorLength > 0) return descriptorLength
        return null
    }

    /** Only a file with a known size at or below the ceiling may reach the WebView. */
    fun withinLimit(bytes: Long?, maxBytes: Long): Boolean = bytes != null && bytes <= maxBytes

    /**
     * The name of a staged copy. One path component, never `.` or `..`, no
     * separator or control character, bounded: it comes from another app.
     */
    fun stagedName(raw: String?): String {
        val component = (raw ?: "").substringAfterLast('/').substringAfterLast('\\')
        val cleaned = component.filter { !it.isISOControl() && it != '/' && it != '\\' }.trim()
        val safe = cleaned.take(96).trim()
        return if (safe.isEmpty() || safe == "." || safe == "..") "file" else safe
    }
}
