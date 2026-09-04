package com.readvibe.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** Channel adaptation only: document work never executes in a UI callback. */
internal class PdfChannelHandler(context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.readvibe.app/pdf_renderer")
    private val engine = PdfDocumentEngine(context)
    private val renderExecutor = Executors.newSingleThreadExecutor()
    private val analysisExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val replies = Executor { mainHandler.post(it) }
    @Volatile private var disposed = false
    private val renderTasks = BackgroundTaskRunner(renderExecutor, replies) { !disposed }
    private val analysisTasks = BackgroundTaskRunner(analysisExecutor, replies) { !disposed }

    init {
        channel.setMethodCallHandler { call, result ->
            val operation = PdfOperation.fromMethod(call.method)
            val filePath = call.argument<String>("filePath")
            if (operation == null) {
                result.notImplemented()
            } else if (disposed) {
                result.error("PDF_CLOSED", "PDF 服务已关闭", null)
            } else if (filePath.isNullOrBlank()) {
                result.error("PDF_PATH_INVALID", "PDF 文件路径无效", null)
            } else {
                val request = PdfRequest(
                    operation = operation,
                    filePath = filePath,
                    pageIndex = call.argument<Int>("pageIndex") ?: -1,
                    widthPx = call.argument<Int>("widthPx") ?: 1440,
                    query = call.argument<String>("query").orEmpty(),
                    password = call.argument<String>("password").orEmpty(),
                    noteId = call.argument<String>("noteId").orEmpty(),
                    contents = call.argument<String>("contents").orEmpty(),
                )
                val runner = if (operation.analysis) analysisTasks else renderTasks
                runner.submit(
                    work = { engine.execute(request) },
                    onSuccess = result::success,
                    onError = { error ->
                        result.error(
                            if (error is InvalidPasswordException) "PDF_PASSWORD_REQUIRED"
                            else "PDF_RENDER_FAILED",
                            error.message ?: "PDF 已损坏、加密或不受支持",
                            null,
                        )
                    },
                )
            }
        }
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        // Release on the owning worker after its active operation completes.
        // Queued tasks see disposed and skip work; the UI never waits for OCR.
        renderExecutor.execute { engine.closeRenderResources() }
        analysisExecutor.execute { engine.closeAnalysisResources() }
        renderExecutor.shutdown()
        analysisExecutor.shutdown()
    }
}
