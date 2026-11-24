package com.nearlink.chat

import android.content.Context

/** UI-only preference: never stores an identity, alias, key or message. */
object AppDisplayLanguage {
    private const val PREFERENCES = "whisplot_display_language"
    fun text(context: Context, zh: String, en: String): String =
        if (context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .getString("language", "en") == "zh") zh else en

    fun set(context: Context, language: String) {
        require(language == "zh" || language == "en")
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit().putString("language", language).apply()
    }
}
