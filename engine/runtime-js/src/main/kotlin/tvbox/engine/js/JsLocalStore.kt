package tvbox.engine.js

import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import java.io.File

/** `local.get/set/delete` storage for JS spiders (TVBox keeps these in Hawk). */
interface JsLocalStore {
    fun get(key: String): String?
    fun set(key: String, value: String)
    fun delete(key: String)
}

class MemoryJsLocalStore : JsLocalStore {
    private val map = HashMap<String, String>()
    @Synchronized override fun get(key: String) = map[key]
    @Synchronized override fun set(key: String, value: String) { map[key] = value }
    @Synchronized override fun delete(key: String) { map.remove(key) }
}

/** A single JSON file; small and written on every change. */
class FileJsLocalStore(private val file: File) : JsLocalStore {
    private val gson = Gson()
    private val map: MutableMap<String, String> = runCatching {
        gson.fromJson<MutableMap<String, String>>(file.readText(), object : TypeToken<MutableMap<String, String>>() {}.type)
    }.getOrNull() ?: HashMap()

    @Synchronized override fun get(key: String) = map[key]

    @Synchronized override fun set(key: String, value: String) {
        map[key] = value
        save()
    }

    @Synchronized override fun delete(key: String) {
        if (map.remove(key) != null) save()
    }

    private fun save() {
        runCatching {
            file.parentFile?.mkdirs()
            val tmp = File(file.path + ".tmp")
            tmp.writeText(gson.toJson(map))
            if (!tmp.renameTo(file)) {
                file.delete()
                tmp.renameTo(file)
            }
        }
    }
}
