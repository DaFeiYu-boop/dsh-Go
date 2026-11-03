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
 * 进阶模式的白名单判定。只做静态检查：挡得住手滑，挡不住蓄意。
 */
object ShellGuard {

    /** 进阶模式永久禁止：一旦执行就不可挽回。 */
    val LOCKED = setOf(
        "dd", "mkfs", "mke2fs", "mkntfs", "mkdosfs", "fdisk", "parted", "sgdisk", "gdisk",
        "fastboot", "setenforce", "insmod", "rmmod", "modprobe", "wipe", "chroot",
        "pivot_root", "reboot", "shutdown", "halt",
    )

    /** 脚本执行类：能跑任意代码，进阶模式下每次确认。 */
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

    /** App 自己的私有目录：只在进阶模式下放行，且要躲开 [FORBIDDEN] 里的 /data/data/。 */
    private val APP_PRIVATE = listOf(
        "/data/user/0/io.github.ccch1mneyyy.dsh_app/",
        "/data/data/io.github.ccch1mneyyy.dsh_app/",
    )

    /** 永远可写的几个位置。 */
    private val BASE_ROOTS = listOf(
        "/sdcard/Download/", "/storage/emulated/0/Download/",
        "/data/local/tmp/",
    ) + APP_PRIVATE

    /** 用户单独确认过「整个 /sdcard」之后才能写的位置。 */
    private val SDCARD_ROOTS = listOf("/sdcard/", "/storage/emulated/0/")

    /** 会改文件的命令：目标必须落在 [SAFE_ROOTS]。 */
    /** 命令替换：$( )、${ }、反引号。能把任意命令藏进参数。 */
    private val SUBST = Regex("""\$\(|\$\{|`""")

    private val WRITE_CMDS = setOf(
        "rm", "mv", "cp", "mkdir", "rmdir", "touch", "chmod", "chown", "ln", "tee", "truncate",
        "sed", "awk",
    )

    /**
     * 相册里的路径只允许这些命令碰：它们没有「把内容写到指定文件」的参数。
     * 只读组里 `sort -o`、`logcat -f`、`curl -o` 都能写文件，所以按命令白名单，
     * 不按「只读组」——名单外的一律当「可能写」处理。
     * 相册在进阶模式下是**纯只读**：连复制出去都不许（要复制请切高危）。
     */
    val PHOTO_READ = setOf(
        "ls", "cat", "head", "tail", "grep", "find", "file", "stat",
        "du", "wc", "cut", "tr", "uniq",
    )

    /** 相册/视频目录：可读可写，但不可删、不可覆盖已有文件。 */
    private val PHOTO_DIRS = listOf(
        "/sdcard/DCIM/", "/storage/emulated/0/DCIM/",
        "/sdcard/Pictures/", "/storage/emulated/0/Pictures/",
        "/sdcard/Movies/", "/storage/emulated/0/Movies/",
        "/sdcard/Android/media/", "/storage/emulated/0/Android/media/",
    )

    fun judge(
        mode: ShellMode,
        command: String,
        allowed: Set<String>,
        sdcardOn: Boolean = false,
    ): ShellVerdict {
        val cmd = command.trim()
        if (cmd.isEmpty()) return ShellVerdict.Deny("命令是空的。")

        // 高危：命令、路径全放开。用户已经明确选了这个档位。
        if (mode == ShellMode.FULL) return ShellVerdict.Allow

        // 命令替换能把任意命令藏进参数里（$(pm uninstall ...)），这里一律不接受。
        // 正经用法用不到它；确实要跑脚本，请切到高危模式。
        if (SUBST.containsMatchIn(cmd)) {
            return ShellVerdict.Deny(
                "命令里有 \$(...)、\${...} 或反引号——它们能把别的命令藏起来绕开检查，进阶模式下不允许。要跑这种命令请切到高危模式。",
            )
        }

        for (seg in split(cmd)) {
            val word = firstWord(seg) ?: continue

            // 整组锁死：不管 allowed 里有没有，进阶模式一律拒绝。
            val group = ShellCommands.groupOf(word)
            if (group != null && group in ShellCommands.SAFE_LOCKED_GROUPS) {
                return ShellVerdict.Deny(
                    "「$word」属于「${ShellCommands.groupTitle(group)}」，进阶模式下整组锁死，切到高危模式才能用。",
                )
            }
            if (word in LOCKED) {
                return ShellVerdict.Deny(
                    "「$word」可能损坏分区或系统，进阶模式下不可用。要跑它请切到高危模式。",
                )
            }
            if (word !in allowed) {
                return ShellVerdict.Deny(
                    "「$word」没有在当前档位开启。去 设置 → 终端权限 里的命令清单把它打开。",
                )
            }

            // `cd` 会改工作目录：只许进安全目录，否则 `cd 相册 && rm *` 能用相对路径
            // 绕过全部保护（pathArgs 只抓绝对路径，相对路径根本进不了检查）。
            if (word == "cd") {
                val dest = pathArgs(seg).firstOrNull()
                if (dest != null) {
                    // 相册/视频目录：即使开了 sdcard 也不许 cd 进去，
                    // 否则 `cd 相册 && rm *` 用相对路径就绕过了照片保护。
                    if (inPhoto(dest)) {
                        return ShellVerdict.Deny("「cd」不能进相册/视频目录（$dest）。")
                    }
                    if (!inSafeRoot(dest, sdcardOn)) {
                        return ShellVerdict.Deny(
                            "「cd」只能进 Download、/data/local/tmp 或 App 私有目录，$dest 不行。",
                        )
                    }
                }
            }

            val paths = pathArgs(seg)

            // 相册路径 + 名单外的命令 → 一律拒。这条挡的是 `sort -o 相册/x`、
            // `logcat -f 相册/x`、`curl -o 相册/x` 这类「只读组里能写」的命令。
            val photoArg = paths.firstOrNull { inPhoto(it) }
            if (photoArg != null && word !in PHOTO_READ) {
                return ShellVerdict.Deny(
                    "「$word」的参数里有相册里的路径（$photoArg）。进阶模式下相册只给读，" +
                        "只允许 " + PHOTO_READ.joinToString("、") +
                        " 这些命令。能写文件的命令（sort -o、logcat -f、curl -o 之类）一律不许。",
                )
            }
            for (p in paths) {
                forbidden(p, sdcardOn)?.let { hit ->
                    return ShellVerdict.Deny("碰到受保护的位置：$hit，进阶模式下不允许。")
                }
                if (!sdcardOn && (p.startsWith("/sdcard/") || p.startsWith("/storage/emulated/0/")) &&
                    !inSafeRoot(p, false)
                ) {
                    return ShellVerdict.Deny(
                        "「$word」碰到了 $p。要让 AI 读写整个 /sdcard，去 设置 → 终端权限 → 额外设置 里打开「允许读写整个 /sdcard」。",
                    )
                }
            }

            // 重定向目标也是一次写入：`echo x > /path` 的 /path 必须过同样的检查，
            // 否则它能把相册覆盖保护、sdcard 开关全绕过去。
            for (p in redirectTargets(seg)) {
                if (!p.startsWith("/")) continue
                if (!inSafeRoot(p, sdcardOn)) {
                    return ShellVerdict.Deny(outOfScope(word, p, sdcardOn))
                }
                if (inPhoto(p)) {
                    return ShellVerdict.Deny(
                        "相册是只读的（$p）。进阶模式下只能看和复制出去，不能往里写、也不能删。",
                    )
                }
            }

            if (word in WRITE_CMDS) {
                // `cd /sdcard/Download && rm ../Pictures/x` 这种相对跳转能绕过路径检查
                // （pathArgs 只看绝对路径），写类命令一律不许带 `..`。
                if (seg.contains("..")) {
                    return ShellVerdict.Deny(
                        "「$word」的参数里有 `..`，进阶模式不支持用相对路径跳到别的目录。",
                    )
                }
                // `cp -t 目录 源` 里 -t 后面那串才是目标，其余全是源；
                // 按普通「最后一个参数是目标」处理会把 -t 的目录误判成源。
                val hasTargetFlag = Regex("""(^|\s)-t(\s|$)""").containsMatchIn(seg)
                val isMove = !hasTargetFlag && (word == "cp" || word == "mv" || word == "ln")
                val targets = if (isMove) paths.takeLast(1) else paths
                // 源也要查：`mv 相册/x Download/` 不看源就能把照片搬出相册，
                // 搬出去等于从相册消失了——和删掉一个效果，必须拦在源上。
                // 源在相册一律拒：`mv` 是搬走，`cp` 是复制出去，进阶模式两个都不许。
                if (isMove && paths.size > 1) {
                    for (src in paths.dropLast(1)) {
                        if (inPhoto(src)) {
                            return ShellVerdict.Deny(
                                "「$src」在相册/视频目录里，搬出去就等于从相册消失了，进阶模式下不允许。要动它请切到高危模式。",
                            )
                        }
                    }
                }
                for (p in targets) {
                    if (!p.startsWith("/")) {
                        return ShellVerdict.Deny("「$word」的目标要写绝对路径，$p 不是。")
                    }
                    if (!inSafeRoot(p, sdcardOn)) {
                        return ShellVerdict.Deny(outOfScope(word, p, sdcardOn))
                    }
                    if (inPhoto(p)) {
                        return ShellVerdict.Deny(
                            "相册是只读的（$p）。进阶模式下只能看和复制出去，不能往里写、也不能删。",
                        )
                    }
                }
            }
            if (word == "find" && Regex("""\s-(delete|exec|execdir|ok|okdir)\b""").containsMatchIn(seg)) {
                return ShellVerdict.Deny("find 带 -delete/-exec 等于执行任意操作，进阶模式下不可用。")
            }
            if (word == "pm" && Regex("""\bpm\s+clear\b""").containsMatchIn(seg)) {
                return ShellVerdict.Deny("pm clear 会清掉一个 App 的全部数据，进阶模式下不可用。")
            }
        }
        return ShellVerdict.Allow
    }

    /** 按 `;` `&&` `||` `|` 拆段；每段都要单独过白名单。 */
    private fun split(cmd: String): List<String> =
        cmd.split(Regex("""(?:\|\||&&|;|\|(?!\|)|\r?\n)"""))
            .map { it.trim() }
            .filter { it.isNotEmpty() }

    /** 段首词，去掉路径和引号：`/system/bin/ls -la` → `ls`。 */
    private fun firstWord(seg: String): String? {
        val m = Regex("""^[^\s;&|()<>`]+""").find(seg.trimStart()) ?: return null
        val w = m.value.substringAfterLast('/').trim('\'', '"').lowercase()
        return w.ifEmpty { null }
    }

    /** 系统分区 / 别的 App 数据：不管开没开 sdcard 都不许碰。 */
    private fun forbidden(p: String, sdcardOn: Boolean = false): String? {
        val withSlash = if (p.endsWith("/")) p else "$p/"
        // App 自己的私有目录永远放行（FORBIDDEN 里的 /data/data/ 不能一刀切到它头上）。
        if (APP_PRIVATE.any { withSlash.startsWith(it) }) return null
        for (f in FORBIDDEN) {
            if (withSlash != f && !withSlash.startsWith(f)) continue
            // 开了「允许读写 sdcard」后，/sdcard 下的目录交给 inSafeRoot + 相册规则判断，
            // 不再在这里一刀切。
            if (sdcardOn && (f.startsWith("/sdcard/") || f.startsWith("/storage/emulated/0/"))) continue
            return p
        }
        return null
    }

    /** 参数里的绝对路径，跳过重定向符号（`2>&1`、`>`、`>>`）。 */
    /** `> path`、`>> path`、`>/path` 的目标（相对路径交给调用方跳过）。 */
    private fun redirectTargets(seg: String): List<String> =
        Regex("""(?:^|[^>])>>?\s*([^\s;&|]+)""").findAll(seg)
            .map { it.groupValues[1].trim('\'', '"') }
            .toList()

    private fun pathArgs(seg: String): List<String> =
        Regex("""(?:^|[\s>])(/[^\s'"`()|;&<>]+)""").findAll(seg)
            .map { it.groupValues[1] }
            .toList()

    /** 规范化后是否落在允许写的位置。[sdcardOn] = 用户是否确认过「整个 /sdcard」。 */
    private fun inSafeRoot(p: String, sdcardOn: Boolean): Boolean {
        val norm = try {
            java.nio.file.Paths.get(p).normalize().toString()
        } catch (_: Exception) {
            return false
        }
        // 黑洞设备：写进去什么都不会发生，`2>/dev/null` 是最常见的写法，放行。
        if (norm == "/dev/null") return true
        val withSlash = if (norm.endsWith("/")) norm else "$norm/"
        if (sdcardOn && SDCARD_ROOTS.any { withSlash.startsWith(it) }) return true
        return BASE_ROOTS.any { withSlash.startsWith(it) }
    }

    /** 是否在相册/视频目录里。 */
    private fun inPhoto(p: String): Boolean {
        val norm = try {
            java.nio.file.Paths.get(p).normalize().toString()
        } catch (_: Exception) {
            return false
        }
        val withSlash = if (norm.endsWith("/")) norm else "$norm/"
        return PHOTO_DIRS.any { withSlash.startsWith(it) }
    }

    /** 拒绝时说清「去哪开」。 */
    private fun outOfScope(word: String, p: String, sdcardOn: Boolean): String =
        if (!sdcardOn && (p.startsWith("/sdcard") || p.startsWith("/storage/emulated/0"))) {
            "「$word」只能改 Download 和 /data/local/tmp，这一条碰到了 $p。" +
                "要让 AI 读写整个 /sdcard，去 设置 → 终端权限 → 额外设置 里打开「允许读写整个 /sdcard」。"
        } else {
            "「$word」碰到了一个不在允许范围内的位置：$p。"
        }
}

/** 命令清单：设置页按组展示，默认值也在这里。 */
object ShellCommands {
    /** 分组顺序 + 中文标题 + 一句话说明。 */
    val GROUPS: List<Map<String, String>> = listOf(
        linkedMapOf("id" to "read", "title" to "只读命令", "desc" to "只看不改：读文件、看进程和系统状态"),
        linkedMapOf("id" to "file", "title" to "文件操作", "desc" to "复制、移动、删除；只能碰 Download、tmp、App 私有目录（开 /sdcard 后含整个存储）"),
        linkedMapOf("id" to "system", "title" to "系统操作", "desc" to "安卓层面的开关：装应用、模拟点击、改设置"),
        linkedMapOf("id" to "network", "title" to "网络", "desc" to "联网请求、测速、查 DNS"),
        linkedMapOf("id" to "packages", "title" to "包管理", "desc" to "apt / pip / npm / git，第一次用要联网下载"),
        linkedMapOf("id" to "script", "title" to "脚本执行", "desc" to "把整段脚本交给解释器：内容不受白名单约束"),
    )

    /** 命令 → (分组, 一句话介绍)。 */
    private val DEF: List<Triple<String, String, String>> = listOf(
        Triple("cd", "read", "切当前目录（只在同一条命令里有效）"),
        Triple("pwd", "read", "打印当前目录"),
        Triple("echo", "read", "打印一段文字"),
        Triple("ls", "read", "列出目录内容"),
        Triple("cat", "read", "输出文件内容"),
        Triple("head", "read", "看文件开头几行"),
        Triple("tail", "read", "看文件结尾几行"),
        Triple("grep", "read", "在文件或输出里搜文字"),
        Triple("wc", "read", "数行数、字数"),
        Triple("sort", "system", "排序（带 -o 会写文件）"),
        Triple("uniq", "read", "去重"),
        Triple("cut", "read", "按列截取"),
        Triple("find", "read", "按名字/时间找文件"),
        Triple("stat", "read", "看文件大小、权限、时间"),
        Triple("file", "read", "判断文件是什么类型"),
        Triple("du", "read", "看目录占多少空间"),
        Triple("df", "read", "看各分区剩余空间"),
        Triple("free", "read", "看内存占用"),
        Triple("ps", "read", "看正在跑的进程"),
        Triple("top", "read", "看谁在吃 CPU"),
        Triple("uptime", "read", "开机多久、负载多少"),
        Triple("id", "read", "看当前用户和权限"),
        Triple("whoami", "read", "看当前用户名"),
        Triple("getprop", "read", "读系统属性：型号、Android 版本"),
        Triple("dumpsys", "read", "读系统服务状态：电池、显示、WiFi"),
        Triple("logcat", "system", "读系统日志（带 -f 会写文件）"),
        Triple("screencap", "read", "截屏存成图片"),
        Triple("date", "system", "看时间（带 -s 会改系统时间）"),
        Triple("echo", "read", "输出一段文字"),
        Triple("printf", "read", "格式化输出文字"),
        Triple("pwd", "read", "显示当前目录"),
        Triple("env", "read", "看环境变量"),
        Triple("uname", "read", "看内核版本"),
        Triple("nproc", "read", "看有几个 CPU 核"),
        Triple("which", "read", "查命令装在哪"),
        Triple("basename", "read", "取路径里的文件名"),
        Triple("dirname", "read", "取路径里的目录部分"),
        Triple("realpath", "read", "把相对路径转成绝对路径"),
        Triple("tr", "read", "替换或删除字符"),
        Triple("cp", "file", "复制文件"),
        Triple("mv", "file", "移动或改名"),
        Triple("rm", "file", "删除文件"),
        Triple("mkdir", "file", "新建目录"),
        Triple("rmdir", "file", "删除空目录"),
        Triple("touch", "file", "新建空文件或改时间"),
        Triple("chmod", "file", "改文件权限"),
        Triple("chown", "file", "改文件属主"),
        Triple("ln", "file", "建快捷方式（软链接）"),
        Triple("tee", "file", "把输出同时写进文件"),
        Triple("truncate", "file", "把文件截断或撑大"),
        Triple("sed", "file", "按规则替换文件内容"),
        Triple("awk", "file", "按列处理文本"),
        Triple("am", "system", "启动应用、发广播"),
        Triple("pm", "packages", "装/卸应用、查包名"),
        Triple("input", "system", "模拟点屏幕、打字"),
        Triple("cmd", "system", "调系统命令（WiFi、电池等）"),
        Triple("settings", "system", "读改系统设置项"),
        Triple("svc", "system", "开关 WiFi、数据、飞行模式"),
        Triple("wm", "system", "改屏幕分辨率、密度"),
        Triple("curl", "network", "发 HTTP 请求"),
        Triple("ping", "network", "测网络通不通"),
        Triple("nslookup", "network", "查域名对应 IP"),
        Triple("netstat", "network", "看网络连接"),
        Triple("apt", "packages", "装系统软件包"),
        Triple("apt-get", "packages", "装系统软件包（老写法）"),
        Triple("pip", "packages", "装 Python 包"),
        Triple("pip3", "packages", "装 Python 3 包"),
        Triple("npm", "packages", "装 Node 包"),
        Triple("pnpm", "packages", "装 Node 包（更快）"),
        Triple("git", "packages", "拉代码、提交"),
        Triple("sh", "script", "跑一段 shell 脚本"),
        Triple("bash", "script", "跑一段 bash 脚本"),
        Triple("zsh", "script", "跑一段 zsh 脚本"),
        Triple("python", "script", "跑 Python 代码"),
        Triple("python3", "script", "跑 Python 3 代码"),
        Triple("node", "script", "跑 JavaScript 代码"),
        Triple("eval", "script", "把字符串当命令执行"),
        Triple("exec", "script", "替换成另一个进程执行"),
        Triple("xargs", "script", "把输入拼成命令批量执行"),
        Triple("source", "script", "加载脚本文件"),
    )

    /** 设置页用的扁平清单，每项带分组和介绍。 */
    val CATALOG: List<Map<String, Any?>> = DEF.map {
        linkedMapOf<String, Any?>("name" to it.first, "group" to it.second, "desc" to it.third)
    }

    /** 进阶模式下整组锁死、不可打开的组。 */
    val SAFE_LOCKED_GROUPS: Set<String> = setOf("packages", "script")

    /** 危险到进阶模式不该默认开的单条命令（可手动开，但默认关）。 */
    private val SAFE_OFF: Set<String> = setOf(
        "rm", "rmdir", "chmod", "chown", "truncate", "ln", "mv",
        "am", "pm", "input", "settings", "svc", "wm", "curl",
        // 这几条名字像只读，实际带写参数：sort -o / logcat -f 能写文件，
        // date -s 能改系统时间。默认关，要用自己去额外设置里开。
        "sort", "logcat", "date",
    )

    /** 进阶模式默认打开：只读全开，文件类只留只读性的，系统类关掉能改状态的。 */
    val SAFE_DEFAULT: Set<String> = CATALOG
        .filter { it["group"] !in SAFE_LOCKED_GROUPS }
        .map { it["name"] as String }
        .filter { it !in SAFE_OFF }
        .toSet()

    fun groupOf(name: String): String? = CATALOG.firstOrNull { it["name"] == name }?.get("group") as String?

    fun groupTitle(id: String): String = GROUPS.firstOrNull { it["id"] == id }?.get("title") ?: id

    /** 高危模式默认：除包管理外全开（第一次 apt 要联网下载，默认关）。 */
    val DEFAULT_ALLOWED: Set<String> = CATALOG
        .filter { it["group"] != "packages" }
        .map { it["name"] as String }
        .toSet()
}
