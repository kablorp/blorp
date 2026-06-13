package com.blorp.intellij

object BlorpIdentifiers {
    fun isStart(char: Char): Boolean =
        char == '_' || char in 'a'..'z' || char in 'A'..'Z'

    fun isBody(char: Char): Boolean =
        isStart(char) || char in '0'..'9'
}
