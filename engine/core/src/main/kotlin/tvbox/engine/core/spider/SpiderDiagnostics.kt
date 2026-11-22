package tvbox.engine.core.spider

import kotlinx.coroutines.CancellationException
import tvbox.engine.core.model.SpiderDiagnostic
import tvbox.engine.core.net.SiteHttpException
import tvbox.engine.core.vod.SiteResultException
import java.io.IOException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.Collections
import java.util.IdentityHashMap
import javax.net.ssl.SSLException

private val siteId = Regex("[\\p{L}\\p{N}_.-]{1,64}")
private val javaSymbol = Regex("^(?:Class |'[A-Za-z_.$]+ )?((?:android|androidx|dalvik|java|com\\.github\\.catvod)(?:\\.[A-Za-z_$][A-Za-z_$0-9]*)+)(?:$|[ (';])")
private val exceptionName = Regex("[A-Za-z_$][A-Za-z_$0-9]{0,79}")
private val fieldName = Regex("member field '[A-Za-z_$][A-Za-z0-9_.$\\[\\]]* ([A-Za-z_$][A-Za-z0-9_$]{0,63})'")
private val nativeAbi = Regex("\\b(?:armeabi-v7a|arm64-v8a|x86_64|x86)\\b")
private val jniReasons = setOf(
    "Android JNI: unsupported signature", "Android JNI: guest timed out", "Android JNI: guest unavailable",
    "Android JNI: native call failed", "Android JNI: guest initialization failed",
)
private val missingCommand = Regex("Cannot run program \"(chmod|killall|nohup|sh)\"")
private val httpStatus = Regex("^HTTP ([1-5]\\d\\d) for ")
private val resultMessages = setOf("detail is empty", "site returned invalid JSON", "site returned non-object JSON", "site returned no play url", "empty quality list", "spider returned no play info")

fun spiderArchiveId(spec: String): String? = spec.substringBefore(";md5;").trim().takeIf { it.isNotEmpty() }?.let { JarRepository.md5(it).take(12) }

fun spiderDiagnostic(site: String, stage: String, error: Throwable, archive: String? = null, initCause: String? = null): SpiderDiagnostic {
    val seen = Collections.newSetFromMap(IdentityHashMap<Throwable, Boolean>())
    val causes = generateSequence(error) { it.cause }.take(16).takeWhile { seen.add(it) }.toList()
    for (cause in causes) {
        if (cause is CancellationException || cause is VirtualMachineError || cause is ThreadDeath) throw cause
    }
    val root = causes.last()
    val nativeErrors = causes.filterIsInstance<UnsatisfiedLinkError>()
    val jniReason = nativeErrors.asReversed().firstNotNullOfOrNull { it.message?.takeIf(jniReasons::contains) }
    val networkError = causes.lastOrNull { it is SocketException || it is SocketTimeoutException || it is UnknownHostException || it is SSLException || it is SiteHttpException }
    val command = causes.filterIsInstance<IOException>().firstNotNullOfOrNull { missingCommand.find(it.message.orEmpty().take(120))?.groupValues?.get(1) }
    val archiveResponse = if (stage == "jar.fetch" && root is IllegalStateException) {
        val message = root.message.orEmpty()
        when {
            message.endsWith(", not a jar") || message.startsWith("no jar inside image ") -> "response does not contain a JAR"
            message.startsWith("empty jar body from ") -> "empty JAR response"
            else -> httpStatus.find(message.take(24))?.groupValues?.get(1)?.let { "HTTP $it" }
        }
    } else null
    val kind = when {
        nativeErrors.isNotEmpty() -> "native"
        root is NoClassDefFoundError || root is ClassNotFoundException -> "missing_class"
        root is NoSuchFieldError || root is NoSuchMethodError || root is NoSuchFieldException || root is NoSuchMethodException || root is AbstractMethodError -> "missing_member"
        command != null -> "command"
        archiveResponse != null || networkError != null -> "network"
        root is SiteResultException -> "invalid_result"
        else -> "other"
    }
    val message = root.message.orEmpty().take(300)
    val hint = when (kind) {
        "missing_class", "missing_member" -> javaSymbol.find(message.replace('/', '.'))?.groupValues?.get(1)?.take(120)?.let { owner ->
            fieldName.find(message)?.groupValues?.get(1)?.let { "$owner.$it" } ?: owner
        }
        "native" -> jniReason ?: nativeAbi.find(nativeErrors.last().message.orEmpty().take(300))?.value
        "network" -> archiveResponse
        "invalid_result" -> message.takeIf { it in resultMessages }
        "command" -> command
        else -> null
    }
    val type = when {
        nativeErrors.isNotEmpty() -> "UnsatisfiedLinkError"
        kind == "network" && networkError != null -> networkError.javaClass.simpleName.takeIf(exceptionName::matches)
        else -> root.javaClass.simpleName.takeIf(exceptionName::matches)
    } ?: "Throwable"
    val detail = listOfNotNull(type, hint).joinToString(": ")
    val siteLabel = if (site.isEmpty() || siteId.matches(site)) site else "site-${JarRepository.md5(site).take(12)}"
    return SpiderDiagnostic(stage, siteLabel, kind, detail, archive, initCause)
}

fun SpiderDiagnostic.summary(): String = buildString {
    append(stage)
    if (site.isNotEmpty()) append(" site=").append(site)
    archive?.let { append(" jar=").append(it) }
    append(" · ").append(cause)
    initCause?.let { append(" · jar.init: ").append(it) }
}
