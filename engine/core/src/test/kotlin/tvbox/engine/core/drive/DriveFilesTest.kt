package tvbox.engine.core.drive

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class DriveFilesTest {
    @Test
    fun `paths are normalised and dot-dot, backslashes and colons in local paths are refused`() {
        assertEquals("/", DriveFiles.normalize(""))
        assertEquals("/", DriveFiles.normalize("/"))
        assertEquals("/a/b", DriveFiles.normalize("a//./b/"))
        assertEquals("/a:b", DriveFiles.normalize("/a:b"), "a colon is a normal character on a server")
        for (bad in listOf("/a/../b", "..", "/a/..", "/a\\b", "/a\u0000b")) {
            assertThrows(DriveException::class.java, { DriveFiles.normalize(bad) }, bad)
        }
        assertThrows(DriveException::class.java) { DriveFiles.normalize("/C:/Windows", local = true) }
        assertThrows(DriveException::class.java) { DriveFiles.normalize("/x/file.txt:stream", local = true) }
        assertEquals("/a", DriveFiles.parent("/a/b"))
        assertEquals("/", DriveFiles.parent("/a"))
        assertEquals("/a/b", DriveFiles.join("/a", "/b"))
        assertEquals("/b", DriveFiles.join("/", "/b"))
        assertEquals("/b", DriveFiles.relative("/root/b", "/root"))
        assertEquals("/", DriveFiles.relative("/root", "/root"))
        assertNull(DriveFiles.relative("/rootless/b", "/root"))
    }

    @Test
    fun `segments are percent-encoded and decoded without touching plus signs`() {
        assertEquals("/%E5%89%A7%E9%9B%86/a%20b%2Bc.mp4", DriveFiles.encodePath("/剧集/a b+c.mp4"))
        assertEquals("/剧集/a b+c.mp4", DriveFiles.decodePath("/%E5%89%A7%E9%9B%86/a%20b+c.mp4"))
        assertEquals("/100%", DriveFiles.decodePath("/100%"), "a stray percent sign stays")
    }

    @Test
    fun `episodes sort by the numbers in their names`() {
        val names = listOf("第10集.mp4", "第2集.mp4", "第1集.mp4", "第02集 加长.mp4", "Extra.mkv", "a.mp4")
        assertEquals(listOf("a.mp4", "Extra.mkv", "第1集.mp4", "第02集 加长.mp4", "第2集.mp4", "第10集.mp4"), names.sortedWith(DriveFiles.naturalOrder))
        val entries = listOf(DriveEntry("b.mp4", "/b.mp4", false), DriveEntry("z", "/z", true), DriveEntry("a.mp4", "/a.mp4", false))
        assertEquals(listOf("z", "a.mp4", "b.mp4"), entries.sortedWith(DriveFiles.entryOrder).map { it.name }, "folders first")
    }

    @Test
    fun `files are told apart by extension and subtitles found by base name`() {
        assertEquals("video", DriveFiles.type("Film.MKV", false))
        assertEquals("subtitle", DriveFiles.type("film.ass", false))
        assertEquals("folder", DriveFiles.type("film.mkv", true))
        assertEquals("other", DriveFiles.type("film.nfo", false))
        val siblings = listOf("Film.mkv", "Film.srt", "film.zh.ass", "Film.en.vtt", "Film 2.srt", "Filmography.srt", "Film.nfo").map { DriveEntry(it, "/$it", false) }
        val subs = DriveFiles.subtitlesFor("Film.mkv", siblings)
        assertEquals(listOf("Film.en.vtt" to "en", "Film.srt" to "", "film.zh.ass" to "zh"), subs.map { it.first.name to it.second })
    }

    @Test
    fun `dates from AList and WebDAV`() {
        assertEquals(1714538096789L, DriveFiles.parseIso("2024-05-01T12:34:56.789+08:00"))
        assertEquals(1714566896000L, DriveFiles.parseIso("2024-05-01T12:34:56Z"))
        assertEquals(1714566896123L, DriveFiles.parseIso("2024-05-01T12:34:56.123456789Z"))
        assertEquals(0L, DriveFiles.parseIso("0001-01-01T00:00:00Z"), "Go's zero time is unknown")
        assertEquals(0L, DriveFiles.parseIso("yesterday"))
        assertEquals(1707732000000L, DriveFiles.parseHttpDate("Mon, 12 Feb 2024 10:00:00 GMT"))
        assertEquals(0L, DriveFiles.parseHttpDate(""))
    }

    @Test
    fun `byte ranges`() {
        assertEquals(ByteRange.Whole, ByteRange.parse(null, 100))
        assertEquals(ByteRange.Part(10, 19), ByteRange.parse("bytes=10-19", 100))
        assertEquals(ByteRange.Part(10, 99), ByteRange.parse("bytes=10-", 100))
        assertEquals(ByteRange.Part(10, 99), ByteRange.parse("bytes=10-500", 100))
        assertEquals(ByteRange.Part(90, 99), ByteRange.parse("bytes=-10", 100))
        assertEquals(ByteRange.Unsatisfiable, ByteRange.parse("bytes=100-", 100))
        assertEquals(ByteRange.Whole, ByteRange.parse("bytes=0-1,5-6", 100), "several ranges: the whole file")
        assertEquals(ByteRange.Whole, ByteRange.parse("items=0-1", 100))
    }

    @Test
    fun `PROPFIND answers with any prefix, the 200 propstat, and no document types`() {
        val xml = """<?xml version="1.0"?>
            <multistatus xmlns="DAV:" xmlns:lp1="DAV:">
              <response><href>/dav/</href><propstat><prop><resourcetype><collection/></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response>
              <response><href>http://h/dav/%E5%89%A7/</href>
                <propstat><prop><lp1:getcontentlength/></prop><status>HTTP/1.1 404 Not Found</status></propstat>
                <propstat><prop><lp1:resourcetype><lp1:collection/></lp1:resourcetype><lp1:displayname>剧</lp1:displayname></prop><status>HTTP/1.1 200 OK</status></propstat>
              </response>
              <response><href>/dav/a%20b.mp4</href><propstat><prop><resourcetype/><getcontentlength>1234</getcontentlength>
                <getlastmodified>Mon, 12 Feb 2024 10:00:00 GMT</getlastmodified></prop><status>HTTP/1.1 200 OK</status></propstat></response>
            </multistatus>"""
        val raw = Propfind.parse(xml)!!
        assertEquals(3, raw.size)
        assertEquals(Propfind.Raw("http://h/dav/%E5%89%A7/", "剧", true, 0, 0), raw[1])
        assertEquals(Propfind.Raw("/dav/a%20b.mp4", "", false, 1234, 1707732000000L), raw[2])
        assertNull(Propfind.parse("<html><body>login</body></html>"))
        assertNull(Propfind.parse(""))
        val evil = """<?xml version="1.0"?><!DOCTYPE d [<!ENTITY x SYSTEM "file:///etc/passwd">]><d:multistatus xmlns:d="DAV:"><d:response><d:href>&x;</d:href></d:response></d:multistatus>"""
        assertNull(Propfind.parse(evil), "documents with a DOCTYPE are not parsed at all")
        assertTrue(Propfind.BODY.contains("getcontentlength"))
    }
}
