package tvbox.engine.core.site

import kotlinx.coroutines.runBlocking
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import tvbox.engine.core.config.SiteBean
import tvbox.engine.core.net.SiteHttp
import java.util.concurrent.TimeUnit

class RemoteTimeoutTest {
    @Test
    fun explicitTimeoutReachesPlaybackTransport() = runBlocking {
        val limits = mutableListOf<Int>()
        val client = OkHttpClient.Builder().readTimeout(30, TimeUnit.SECONDS).addInterceptor { chain ->
            limits += chain.readTimeoutMillis()
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body("""{"url":"https://example.test/media"}""".toResponseBody("application/json".toMediaType())).build()
        }.build()
        val http = SiteHttp(client)
        for (seconds in listOf(50, 0)) {
            val site = SiteBean("sample", "sample", 4, "https://example.test/api", timeout = seconds)
            RemoteSource(site, http, ExtResolver(http)).play("sample", "episode")
        }
        assertEquals(listOf(50_000, 30_000), limits)
    }
}
