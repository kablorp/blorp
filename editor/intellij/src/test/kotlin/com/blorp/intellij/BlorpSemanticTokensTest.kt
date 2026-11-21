package com.blorp.intellij

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

class BlorpSemanticTokensTest {
    private fun key(type: String, vararg modifiers: String) =
        blorpTextAttributesKey(type, modifiers.toList())

    @Test
    fun typeAndParameterBesideEachOtherDiffer() {
        assertNotEquals(key("type"), key("parameter"))
        assertNotEquals(key("type"), key("variable"))
        assertNotEquals(key("parameter"), key("variable"))
    }

    @Test
    fun otherNeighboursDiffer() {
        assertNotEquals(key("function"), key("parameter"))
        assertNotEquals(key("function"), key("type"))
        assertNotEquals(key("type"), key("typeParameter"))
        assertNotEquals(key("property"), key("parameter"))
        assertNotEquals(key("keyword"), key("type"))
    }

    @Test
    fun libraryFunctionsDifferFromYourOwn() {
        assertNotEquals(key("function"), key("function", "defaultLibrary"))
    }

    @Test
    fun documentationCommentsDifferFromLineComments() {
        assertNotEquals(key("comment"), key("comment", "documentation"))
    }

    @Test
    fun unmappedKindsFallBackToPlainText() {
        assertEquals(key("variable"), key("namespace"))
        assertEquals(key("variable"), key("somethingNew"))
    }
}
