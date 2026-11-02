package io.github.ccch1mneyyy.dsh_app.phone

/**
 * 终端权限的三档。默认 [ORIGINAL]：安装完不给终端。
 *
 * - [ORIGINAL]：没有 shell 工具，和原版一致。
 * - [SAFE]：只跑用户勾选的命令；危险命令永久拒绝；脚本每次确认。
 * - [FULL]：任意命令。
 */
enum class ShellMode(val key: String) {
    ORIGINAL("original"),
    SAFE("safe"),
    FULL("full"),
    ;

    companion object {
        fun of(key: String?): ShellMode = values().firstOrNull { it.key == key } ?: ORIGINAL
    }
}

/** 一次 shell 调用该不该放行。 */
sealed class ShellVerdict {
    object Allow : ShellVerdict()
    class Deny(val reason: String) : ShellVerdict()
    class Confirm(val reason: String, val script: String?) : ShellVerdict()
}

/**
 * 安全模式的白名单判定。只做静态检查：挡得住手滑，挡不住蓄意。
 */
object ShellGuard {

    /** 安全模式永久禁止：一旦执行就不可挽回。 */
    val LOCKED = setOf(
        "dd", "mkfs", "mke2fs", "mkntfs", "mkdosfs", "fdisk", "parted", "sgdisk", "gdisk",
        "fastboot", "setenforce", "insmod", "rmmod", "modprobe", "wipe", "chroot",
        "pivot_root", "reboot", "shutdown", "halt",
    )

    /** 脚本执行类：能跑任意代码，安全模式下每次确认。 */
    val SCRIPTS = setOf(
        "sh", "bash", "zsh", "dash", "ash", "python", "python3", "perl", "ruby",
        "node", "deno", "eval", "exec", "xargs", "source", ".",
    )

    /** 命中的路径一律拒绝。 */
    private val FORBIDDEN = listOf(
        "/system/", "/vendor/", "/product/", "/apex/", "/odm/",
        "/data/adb/", "/data/data/", "/data/system/", "/data/misc/", "/data/app/", "/data/vendor/",
        "/sdcard/DCIM/", "/sdcard/Android/obb/", "/storage/emulated/0/DCIM/",
    )

    /** 安全模式唯一允许写入的位置。**只有这三个**，别的一律拒绝。 */
    private val SAFE_ROOTS = listOf(
        "/sdcard/Download/", "/storage/emulated/0/Download/",
        "/sdcard/Android/data/", "/storage/emulated/0/Android/data/",
        "/data/local/tmp/",
    )

    /** 会改文件的命令：目标必须落在 [SAFE_ROOTS]。 */
    private val WRITE_CMDS = setOf(
        "rm", "mv", "cp", "mkdir", "rmdir", "touch", "chmod", "chown", "ln", "tee", "truncate",
    )

    fun judge(
        mode: ShellMode,
        command: String,
        allowed: Set<String>,
        scriptConfirmBypass: Boolean,
    ): ShellVerdict {
        val cmd = command.trim()
        if (cmd.isEmpty()) return ShellVerdict.Deny("命令是空的。")
        if (mode == ShellMode.FULL) return ShellVerdict.Allow

        hitsForbidden(cmd)?.let {
            return ShellVerdict.Deny("这条命令碰到受保护的位置：$it。安全模式下不允许。")
        }

        var scriptArg: String? = null
        for (seg in split(cmd)) {
            val word = firstWord(seg) ?: continue
            if (word in LOCKED) {
                return ShellVerdict.Deny(
                    "「$word」在安全模式下永久不可用：它可能损坏分区或系统。要跑它请切到高危模式。",
                )
            }
            if (word in SCRIPTS) {
                scriptArg = scriptArg ?: seg
                continue
            }
            if (word !in allowed) {
                return ShellVerdict.Deny(
                    "「$word」没有在当前档位开启。去 设置 → 手机终端 → 额外设置 里打开。",
                )
            }
            if (word in WRITE_CMDS) {
                val targets = if (word == "cp" || word == "mv" || word == "ln") {
                    pathArgs(seg).takeLast(1)
                } else {
                    pathArgs(seg)
                }
                for (p in targets) {
                    if (!inSafeRoot(p)) {
                        return ShellVerdict.Deny(
                            "「$word」只能改 /sdcard/Download、/sdcard/Android/data、/data/local/tmp 里的东西，这一条碰到了 $p。",
                        )
                    }
                }
                // rm 的相对路径等于「不知道删的是哪」，直接拒绝。
                if (word == "rm") {
                    for (p in plainArgs(seg)) {
                        if (!p.startsWith("/") || !inSafeRoot(p)) {
                            return ShellVerdict.Deny(
                                "rm 只能删绝对路径，而且必须在上面的三个目录里。$p 不符合。",                            )
                        }
                    }
                }
            }
            if (word == "find" && Regex("""\s-(delete|exec|execdir|ok|okdir)\b""").containsMatchIn(seg)) {
                return ShellVerdict.Deny("find 带 -delete/-exec 等于执行任意操作，安全模式下不可用。")
            }
            if (word == "pm" && Regex("""\bpm\s+clear\b""").containsMatchIn(seg)) {
                return ShellVerdict.Deny("pm clear 会清掉一个 App 的全部数据，安全模式下不可用。")
            }
        }

        val needsConfirm = scriptArg != null
        return if (needsConfirm && !scriptConfirmBypass) {
            ShellVerdict.Confirm(
                "这条命令会执行脚本，脚本里可以写任何东西。看清楚再放行。",
                scriptArg,
            )
        } else {
            ShellVerdict.Allow
        }
    }

    /** 按 `;` `&&` `||` `|` 拆段；每段都要单独过白名单。 */
    private fun split(cmd: String): List<String> =
        cmd.split(Regex("""(?:\|\||&&|;|\|(?!\|))"""))
            .map { it.trim() }
            .filter { it.isNotEmpty() }

    /** 段首词，去掉路径和引号：`/system/bin/ls -la` → `ls`。 */
    private fun firstWord(seg: String): String? {
        val m = Regex("""^[^\s;&|()<>`]+""").find(seg.trimStart()) ?: return null
        val w = m.value.substringAfterLast('/').trim('\'', '"').lowercase()
        return w.ifEmpty { null }
    }

    /** 命令里出现的绝对路径，有没有落在受保护区。 */
    private fun hitsForbidden(cmd: String): String? {
        for (m in Regex("""/[^\s'"`()|;&<>]+""").findAll(cmd)) {
            val t = m.value
            val p = if (t.endsWith("/")) t else "$t/"
            for (f in FORBIDDEN) {
                if (p == f || p.startsWith(f)) return t
            }
        }
        return null
    }

    /** 参数里的绝对路径。 */
    private fun pathArgs(seg: String): List<String> =
        Regex("""(?:^|\s)(/[^\s'"`()|;&<>]+)""").findAll(seg)
            .map { it.groupValues[1] }
            .toList()

    /** 非选项参数（不是以 - 开头的）。 */
    private fun plainArgs(seg: String): List<String> =
        seg.split(Regex("""\s+""")).drop(1).filter { it.isNotEmpty() && !it.startsWith("-") }

    /** 规范化后是否落在允许写的位置。 */
    private fun inSafeRoot(p: String): Boolean {
        val norm = try {
            java.nio.file.Paths.get(p).normalize().toString()
        } catch (_: Exception) {
            return false
        }
        val withSlash = if (norm.endsWith("/")) norm else "$norm/"
        return SAFE_ROOTS.any { withSlash.startsWith(it) }
    }
}

/** 命令清单：设置页按组展示，默认值也在这里。 */
object ShellCommands {
    /** 分组：read 只读 / file 文件 / system 安卓 / network 网络 / packages 包管理 / script 脚本。 */
    val CATALOG: List<Map<String, Any?>> = buildList {
        fun g(group: String, vararg names: String) {
            names.forEach { add(linkedMapOf<String, Any?>("name" to it, "group" to group)) }
        }
        g("read", "ls", "cat", "head", "tail", "grep", "wc", "sort", "uniq", "cut", "find", "stat",
            "file", "du", "df", "free", "ps", "top", "uptime", "id", "whoami", "getprop", "dumpsys",
            "logcat", "screencap", "date", "echo", "printf", "pwd", "env", "uname", "nproc", "which",
            "basename", "dirname", "realpath", "tr")
        g("file", "cp", "mv", "rm", "mkdir", "rmdir", "touch", "chmod", "chown", "ln", "tee",
            "truncate", "sed", "awk")
        g("system", "am", "pm", "input", "cmd", "settings", "svc", "wm")
        g("network", "curl", "ping", "nslookup", "netstat")
        g("packages", "apt", "apt-get", "pip", "pip3", "npm", "pnpm", "git")
        g("script", "sh", "bash", "zsh", "python", "python3", "node", "eval", "exec", "xargs", "source")
    }

    /** 默认打开：只读、文件、系统、网络、脚本；包管理默认关（第一次用 apt 会慢且要联网）。 */
    val DEFAULT_ALLOWED: Set<String> = CATALOG
        .filter { it["group"] != "packages" }
        .map { it["name"] as String }
        .toSet()
}
