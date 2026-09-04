package com.readvibe.app

internal enum class PdfOperation(
    val method: String,
    val analysis: Boolean = false,
    val mutatesDocument: Boolean = false,
) {
    PAGE_COUNT("getPageCount"),
    RENDER("renderPage"),
    CLEAR_CACHE("clearFileCache", mutatesDocument = true),
    SEARCH("searchText", analysis = true),
    OUTLINE("getOutline", analysis = true),
    ANNOTATIONS("getTextAnnotations", analysis = true),
    PASSWORD_CHECK("isPasswordProtected", analysis = true),
    UNLOCK("unlockPdf", mutatesDocument = true),
    NOTE("syncTextNote", mutatesDocument = true),
    OCR("recognizePageText", analysis = true);

    companion object {
        fun fromMethod(method: String): PdfOperation? = entries.firstOrNull { it.method == method }
    }
}

/** Immutable channel input, safe to pass to either document worker. */
internal data class PdfRequest(
    val operation: PdfOperation,
    val filePath: String,
    val pageIndex: Int = -1,
    val widthPx: Int = 1440,
    val query: String = "",
    val password: String = "",
    val noteId: String = "",
    val contents: String = "",
)
