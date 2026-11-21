package com.blorp.intellij

import org.eclipse.lsp4j.DefinitionParams
import org.eclipse.lsp4j.Location
import org.eclipse.lsp4j.LocationLink
import org.eclipse.lsp4j.Position
import org.eclipse.lsp4j.Range
import org.eclipse.lsp4j.TextDocumentIdentifier
import org.eclipse.lsp4j.jsonrpc.messages.Either
import kotlin.test.Test
import kotlin.test.assertEquals

class BlorpDefinitionTargetsTest {
    private val here = "file:///work/main.brp"
    private val library = "file:///tmp/blorp-lsp-x/io.brp"

    private fun range(line: Int, start: Int, end: Int) = Range(Position(line, start), Position(line, end))

    private fun request(line: Int, character: Int) =
        DefinitionParams(TextDocumentIdentifier(here), Position(line, character))

    private fun links(vararg links: LocationLink) =
        Either.forRight<List<Location>, List<LocationLink>>(links.toList())

    private fun locations(vararg locations: Location) =
        Either.forLeft<List<Location>, List<LocationLink>>(locations.toList())

    @Test
    fun linkPointsAtTheDeclaredNameNotTheWholeDeclaration() {
        val link = LocationLink(library, range(3, 0, 40), range(3, 5, 10), range(7, 4, 9))
        assertEquals(listOf(Location(library, range(3, 5, 10))), definitionTargets(links(link), request(7, 6)))
    }

    @Test
    fun locationsPassThrough() {
        val location = Location(here, range(1, 10, 16))
        assertEquals(listOf(location), definitionTargets(locations(location), request(5, 12)))
    }

    @Test
    fun requestOnTheDeclaredNameItselfHasNoTarget() {
        val declaration = Location(here, range(1, 10, 16))
        assertEquals(emptyList(), definitionTargets(locations(declaration), request(1, 12)))
        assertEquals(emptyList(), definitionTargets(locations(declaration), request(1, 16)))
    }

    @Test
    fun sameRangeInAnotherFileIsATarget() {
        val elsewhere = Location(library, range(1, 10, 16))
        assertEquals(listOf(elsewhere), definitionTargets(locations(elsewhere), request(1, 12)))
    }
}
