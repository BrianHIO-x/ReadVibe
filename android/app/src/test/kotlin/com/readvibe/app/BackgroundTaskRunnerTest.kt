package com.readvibe.app

import java.util.ArrayDeque
import java.util.concurrent.Executor
import java.util.concurrent.RejectedExecutionException
import org.junit.Assert.*
import org.junit.Test

class BackgroundTaskRunnerTest {
    private class Queue : Executor {
        val tasks = ArrayDeque<Runnable>()
        override fun execute(command: Runnable) { tasks.addLast(command) }
        fun next() { tasks.removeFirst().run() }
    }

    @Test fun workCompletesBeforeReplyIsDispatched() {
        val worker = Queue()
        val ui = Queue()
        val events = mutableListOf<String>()
        BackgroundTaskRunner(worker, ui).submit(
            work = { events.add("work"); 42 },
            onSuccess = { events.add("reply:$it") },
            onError = { throw AssertionError(it) },
        )
        assertTrue(events.isEmpty())
        assertTrue(ui.tasks.isEmpty())
        worker.next()
        assertEquals(listOf("work"), events)
        ui.next()
        assertEquals(listOf("work", "reply:42"), events)
    }

    @Test fun workerErrorsAreDeliveredOnReplyExecutor() {
        val worker = Queue()
        val ui = Queue()
        val failure = IllegalArgumentException("invalid document")
        var received: Throwable? = null
        BackgroundTaskRunner(worker, ui).submit(
            work = { throw failure },
            onSuccess = { fail("must not succeed") },
            onError = { received = it },
        )
        worker.next()
        assertNull(received)
        ui.next()
        assertSame(failure, received)
    }

    @Test fun disposingSuppressesQueuedWorkAndLateReplies() {
        val worker = Queue()
        val ui = Queue()
        var active = true
        var worked = false
        var replied = false
        val runner = BackgroundTaskRunner(worker, ui) { active }
        runner.submit({ worked = true }, { replied = true }, { replied = true })
        active = false
        worker.next()
        assertFalse(worked)
        assertTrue(ui.tasks.isEmpty())
        active = true
        runner.submit({ worked = true }, { replied = true }, { replied = true })
        worker.next()
        active = false
        ui.next()
        assertTrue(worked)
        assertFalse(replied)
    }

    @Test fun rejectedWorkReportsAnErrorWithoutRunningOnUi() {
        val ui = Queue()
        val worker = Executor { throw RejectedExecutionException() }
        var failed = false
        BackgroundTaskRunner(worker, ui).submit(
            { fail("work must not run") },
            { fail("must not succeed") },
            { failed = it is RejectedExecutionException },
        )
        assertFalse(failed)
        ui.next()
        assertTrue(failed)
    }

    @Test fun everyPdfOperationHasAnExplicitLaneAndMutationPolicy() {
        assertEquals(PdfOperation.entries.size, PdfOperation.entries.map { it.method }.toSet().size)
        for (operation in PdfOperation.entries) assertSame(operation, PdfOperation.fromMethod(operation.method))
        assertNull(PdfOperation.fromMethod("unknown"))
        assertEquals(
            setOf(PdfOperation.SEARCH, PdfOperation.OUTLINE, PdfOperation.ANNOTATIONS,
                PdfOperation.PASSWORD_CHECK, PdfOperation.OCR),
            PdfOperation.entries.filter { it.analysis }.toSet(),
        )
        assertEquals(
            setOf(PdfOperation.UNLOCK, PdfOperation.NOTE, PdfOperation.CLEAR_CACHE),
            PdfOperation.entries.filter { it.mutatesDocument }.toSet(),
        )
    }
}
