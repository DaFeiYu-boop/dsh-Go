package io.github.ccch1mneyyy.dsh_app.phone.background

import android.os.Process
import java.io.File

/**
 * 启动时清掉上一次留下的孤儿引擎。
 *
 * 引擎是 App 用 Process.start() 起的子进程。App 被系统杀掉或崩溃时它收不到通知，
 * 会被 init 收养、继续跑——占内存、占端口，下次启动还可能两份引擎打架。
 *
 * 只杀「ppid == 1 且 uid == 本 App」的进程：那是上一个自己留下的、已经没人管的。
 * 当前引擎有父进程（本 App），所以不会被选中；别的 App 的进程 uid 不同，也不会碰。
 */
internal object OrphanSweep {

    /** 每个进程只扫一次：MainActivity.onCreate 在旋转屏幕、从最近任务回来时也会重跑。 */
    @Volatile
    private var done = false

    fun sweepAsync() {
        if (done) return
        done = true
        Thread {
            runCatching { sweep() }
        }.apply { isDaemon = true }.start()
    }

    private fun sweep() {
        val self = Process.myPid()
        val uid = Process.myUid()
        File("/proc").listFiles()?.forEach { dir ->
            val pid = dir.name.toIntOrNull() ?: return@forEach
            if (pid == self) return@forEach
            if (uidOf(dir) != uid) return@forEach
            if (ppidOf(dir) != 1) return@forEach
            if (!looksLikeEngine(dir)) return@forEach
            runCatching { Process.killProcess(pid) }
        }
    }

    private fun uidOf(dir: File): Int? = runCatching {
        dir.resolve("status").useLines { lines ->
            lines.firstOrNull { it.startsWith("Uid:") }
                ?.removePrefix("Uid:")?.trim()?.split('\t', ' ')?.firstOrNull()?.toIntOrNull()
        }
    }.getOrNull()

    private fun ppidOf(dir: File): Int? = runCatching {
        dir.resolve("stat").readText().substringAfterLast(')').trim().split(' ')[1].toIntOrNull()
    }.getOrNull()

    /** 引擎的 cmdline 一定带 dsh，并且是 web 或 node 那一段；只看这些，别误伤同 uid 的别的进程。 */
    private fun looksLikeEngine(dir: File): Boolean = runCatching {
        val cmd = dir.resolve("cmdline").readBytes().toString(Charsets.UTF_8)
        cmd.contains("dsh") && (cmd.contains("web") || cmd.contains("node"))
    }.getOrDefault(false)
}
