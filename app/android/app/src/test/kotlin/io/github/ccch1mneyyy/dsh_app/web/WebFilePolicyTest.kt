package io.github.ccch1mneyyy.dsh_app.web

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WebFilePolicyTest {
    @Test fun normalizesMimeListsAndExtensionsWithoutDiscardingFilters() {
        val types = WebFilePolicy.acceptTypes(listOf(" image/*, APPLICATION/PDF ", ".pdf", "image/*")) {
            if (it == "pdf") "application/pdf" else null
        }
        assertEquals(listOf("image/*", "application/pdf"), types)
    }

    @Test fun emptyOrUnknownAcceptUsesSystemAllFilesWithoutConstructingAnInvalidIntentType() {
        assertEquals(listOf("*/*"), WebFilePolicy.acceptTypes(emptyList()) { null })
        assertEquals(listOf("*/*"), WebFilePolicy.acceptTypes(listOf("", ".unknown", "image/*;bad")) { null })
        assertEquals(listOf("*/*"), WebFilePolicy.acceptTypes(listOf("image/*", "*/*")) { null })
    }

    @Test fun rejectsPrivateFilePathsOwnProvidersAndMalformedContentUris() {
        val app = "io.github.ccch1mneyyy.dsh_app"
        assertTrue(WebFilePolicy.isExternalContent("content://com.android.providers.downloads.documents/document/12", app))
        assertFalse(WebFilePolicy.isExternalContent("file:///data/user/0/" + app + "/private", app))
        assertFalse(WebFilePolicy.isExternalContent("content://" + app + ".files/private", app))
        assertFalse(WebFilePolicy.isExternalContent("content://" + app + "/private", app))
        assertFalse(WebFilePolicy.isExternalContent("content:///missing", app))
        assertFalse(WebFilePolicy.isExternalContent("https://example.com/file", app))
    }

    @Test fun aDeclaredSizePrefersTheColumnAndTreatsNonPositiveValuesAsUnknown() {
        assertEquals(10L, WebFilePolicy.declaredBytes(10, null))
        assertEquals(20L, WebFilePolicy.declaredBytes(-1, 20))
        assertEquals(20L, WebFilePolicy.declaredBytes(0, 20))
        assertNull(WebFilePolicy.declaredBytes(null, -1))
        assertNull(WebFilePolicy.declaredBytes(0, 0))
        assertNull(WebFilePolicy.declaredBytes(null, null))
    }

    @Test fun aKnownSizeOverTheCeilingIsRefusedAndAnUnknownOneStaysAllowed() {
        val max = 32L * 1024 * 1024
        assertTrue(WebFilePolicy.withinLimit(null, max))
        assertTrue(WebFilePolicy.withinLimit(max, max))
        assertFalse(WebFilePolicy.withinLimit(max + 1, max))
    }

    @Test fun aStagedNameIsAlwaysOneSafeComponent() {
        assertEquals("report.pdf", WebFilePolicy.stagedName("Downloads/report.pdf"))
        assertEquals("report.pdf", WebFilePolicy.stagedName("C:\\Users\\me\\report.pdf"))
        assertEquals("x", WebFilePolicy.stagedName("a/b/../../x"))
        assertEquals("file", WebFilePolicy.stagedName(null))
        assertEquals("file", WebFilePolicy.stagedName(""))
        assertEquals("file", WebFilePolicy.stagedName("."))
        assertEquals("file", WebFilePolicy.stagedName(".."))
        assertEquals("ab", WebFilePolicy.stagedName("a\u0001b"))
        assertEquals(96, WebFilePolicy.stagedName("x".repeat(200)).length)
        assertFalse(WebFilePolicy.stagedName("/etc/passwd").contains('/'))
    }
}
