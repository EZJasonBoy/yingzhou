/*
 * Copyright (C) 2016 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Kotlin port of ExoPlayer's UriUtil.resolve as bundled in TVBox (com.whl.quickjs.wrapper.UriUtil).
 * RFC 3986 reference resolution that, unlike java.net.URI, never throws on the unescaped
 * characters (Chinese domains, spaces) that TVBox configs routinely contain.
 */
package tvbox.engine.core.util

object UriUtil {
    private const val SCHEME_COLON = 0
    private const val PATH = 1
    private const val QUERY = 2
    private const val FRAGMENT = 3

    fun isAbsolute(uri: String?): Boolean = uri != null && indices(uri)[SCHEME_COLON] != -1

    fun resolve(baseUri: String?, referenceUri: String?): String {
        val base = baseUri ?: ""
        val ref = referenceUri ?: ""
        val uri = StringBuilder()

        val refIndices = indices(ref)
        if (refIndices[SCHEME_COLON] != -1) {
            uri.append(ref)
            removeDotSegments(uri, refIndices[PATH], refIndices[QUERY])
            return uri.toString()
        }

        val baseIndices = indices(base)
        if (refIndices[FRAGMENT] == 0) {
            return uri.append(base, 0, baseIndices[FRAGMENT]).append(ref).toString()
        }
        if (refIndices[QUERY] == 0) {
            return uri.append(base, 0, baseIndices[QUERY]).append(ref).toString()
        }
        if (refIndices[PATH] != 0) {
            val baseLimit = baseIndices[SCHEME_COLON] + 1
            uri.append(base, 0, baseLimit).append(ref)
            return removeDotSegments(uri, baseLimit + refIndices[PATH], baseLimit + refIndices[QUERY])
        }
        if (ref[refIndices[PATH]] == '/') {
            uri.append(base, 0, baseIndices[PATH]).append(ref)
            return removeDotSegments(uri, baseIndices[PATH], baseIndices[PATH] + refIndices[QUERY])
        }
        return if (baseIndices[SCHEME_COLON] + 2 < baseIndices[PATH] && baseIndices[PATH] == baseIndices[QUERY]) {
            uri.append(base, 0, baseIndices[PATH]).append('/').append(ref)
            removeDotSegments(uri, baseIndices[PATH], baseIndices[PATH] + refIndices[QUERY] + 1)
        } else {
            val lastSlash = base.lastIndexOf('/', baseIndices[QUERY] - 1)
            val baseLimit = if (lastSlash == -1) baseIndices[PATH] else lastSlash + 1
            uri.append(base, 0, baseLimit).append(ref)
            removeDotSegments(uri, baseIndices[PATH], baseLimit + refIndices[QUERY])
        }
    }

    private fun removeDotSegments(uri: StringBuilder, offsetIn: Int, limitIn: Int): String {
        var offset = offsetIn
        var limit = limitIn
        if (offset >= limit) return uri.toString()
        if (uri[offset] == '/') offset++
        var segmentStart = offset
        var i = offset
        while (i <= limit) {
            val nextSegmentStart = when {
                i == limit -> i
                uri[i] == '/' -> i + 1
                else -> {
                    i++
                    continue
                }
            }
            if (i == segmentStart + 1 && uri[segmentStart] == '.') {
                uri.delete(segmentStart, nextSegmentStart)
                limit -= nextSegmentStart - segmentStart
                i = segmentStart
            } else if (i == segmentStart + 2 && uri[segmentStart] == '.' && uri[segmentStart + 1] == '.') {
                val prevSegmentStart = uri.lastIndexOf("/", segmentStart - 2) + 1
                val removeFrom = if (prevSegmentStart > offset) prevSegmentStart else offset
                uri.delete(removeFrom, nextSegmentStart)
                limit -= nextSegmentStart - removeFrom
                segmentStart = prevSegmentStart
                i = prevSegmentStart
            } else {
                i++
                segmentStart = i
            }
        }
        return uri.toString()
    }

    private fun indices(s: String): IntArray {
        val result = IntArray(4)
        if (s.isEmpty()) {
            result[SCHEME_COLON] = -1
            return result
        }
        val length = s.length
        var fragmentIndex = s.indexOf('#')
        if (fragmentIndex == -1) fragmentIndex = length
        var queryIndex = s.indexOf('?')
        if (queryIndex == -1 || queryIndex > fragmentIndex) queryIndex = fragmentIndex
        var schemeIndexLimit = s.indexOf('/')
        if (schemeIndexLimit == -1 || schemeIndexLimit > queryIndex) schemeIndexLimit = queryIndex
        var schemeIndex = s.indexOf(':')
        if (schemeIndex > schemeIndexLimit) schemeIndex = -1
        val hasAuthority = schemeIndex + 2 < queryIndex && s[schemeIndex + 1] == '/' && s[schemeIndex + 2] == '/'
        val pathIndex = if (hasAuthority) {
            val p = s.indexOf('/', schemeIndex + 3)
            if (p == -1 || p > queryIndex) queryIndex else p
        } else {
            schemeIndex + 1
        }
        result[SCHEME_COLON] = schemeIndex
        result[PATH] = pathIndex
        result[QUERY] = queryIndex
        result[FRAGMENT] = fragmentIndex
        return result
    }
}
