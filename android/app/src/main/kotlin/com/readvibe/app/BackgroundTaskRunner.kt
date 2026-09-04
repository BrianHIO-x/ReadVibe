package com.readvibe.app

import java.util.concurrent.Executor

/** Work and errors stay on the worker; only completed values cross to the UI. */
internal class BackgroundTaskRunner(
    private val worker: Executor,
    private val replies: Executor,
    private val isActive: () -> Boolean = { true },
) {
    fun <T> submit(work: () -> T, onSuccess: (T) -> Unit, onError: (Throwable) -> Unit) {
        if (!isActive()) return
        try {
            worker.execute {
                if (!isActive()) return@execute
                val outcome = runCatching(work)
                replies.execute {
                    if (isActive()) outcome.fold(onSuccess, onError)
                }
            }
        } catch (error: java.util.concurrent.RejectedExecutionException) {
            replies.execute { if (isActive()) onError(error) }
        }
    }
}
