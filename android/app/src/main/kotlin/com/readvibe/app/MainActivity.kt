package com.readvibe.app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var readerWindow: ReaderWindowHandler? = null
    private var biometricHandler: BiometricHandler? = null
    private var motionHandler: MotionHandler? = null
    private var updateHandler: AppUpdateHandler? = null
    private var bookExporter: BookExportHandler? = null
    private var pdfHandler: PdfChannelHandler? = null
    private var incomingFileHandler: IncomingFileHandler? = null
    private var bookPickerHandler: BookPickerHandler? = null
    private var docExtractorHandler: DocExtractorHandler? = null
    private var systemTextActionHandler: SystemTextActionHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        readerWindow = ReaderWindowHandler(this, messenger)
        biometricHandler = BiometricHandler(this, messenger)
        motionHandler = MotionHandler(this, messenger)
        updateHandler = AppUpdateHandler(this, messenger)
        bookExporter = BookExportHandler(this, messenger)
        pdfHandler = PdfChannelHandler(applicationContext, messenger)
        incomingFileHandler = IncomingFileHandler(this, messenger, intent)
        bookPickerHandler = BookPickerHandler(this, messenger)
        docExtractorHandler = DocExtractorHandler(this, messenger)
        systemTextActionHandler = SystemTextActionHandler(this, messenger)
    }

    override fun onPause() {
        bookPickerHandler?.onPause()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        bookPickerHandler?.onResume()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        incomingFileHandler?.onNewIntent(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (bookPickerHandler?.onActivityResult(requestCode, resultCode, data) == true) return
        if (bookExporter?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        readerWindow?.dispose()
        readerWindow = null
        biometricHandler?.dispose()
        biometricHandler = null
        motionHandler?.dispose()
        motionHandler = null
        updateHandler?.dispose()
        updateHandler = null
        bookExporter?.dispose()
        bookExporter = null
        pdfHandler?.dispose()
        pdfHandler = null
        incomingFileHandler?.dispose()
        incomingFileHandler = null
        bookPickerHandler?.dispose()
        bookPickerHandler = null
        docExtractorHandler?.dispose()
        docExtractorHandler = null
        systemTextActionHandler?.dispose()
        systemTextActionHandler = null
        super.onDestroy()
    }
}
