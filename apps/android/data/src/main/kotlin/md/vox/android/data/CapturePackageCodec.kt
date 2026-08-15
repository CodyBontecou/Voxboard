package md.vox.android.data

import kotlinx.serialization.json.*
import md.vox.android.capturedomain.*
import java.security.MessageDigest
import java.time.DateTimeException
import java.time.ZoneId

internal const val CONTROL_LIMIT_BYTES = 1_048_576
internal const val AGGREGATE_LIMIT_BYTES = 268_435_456L
internal const val JOURNAL_EVENT_LIMIT = 1024
internal val UUID_PATTERN = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
internal val SHA_PATTERN = Regex("^[0-9a-f]{64}$")
private const val CURRENT_CORE = "0.1.0-alpha.1"
private const val CURRENT_RENDERER = "swift-legacy-m0"
private const val CURRENT_PROFILE = "apple-parity-v1"
private const val FIXED_M3_PRESET_ID = "33333333-3333-4333-8333-333333333333"
private const val ZERO_SHA = "0000000000000000000000000000000000000000000000000000000000000000"

class PackageCodecException(val coarseCode: String) : IllegalArgumentException(coarseCode)
data class AssetManifest(val requestID: String)
data class AdmittedRequest(val requestID: String, val createdAtEpochMillis: Long)
data class JournalBinding(
    val packageVersion: Int,
    val requestContractVersion: Int,
    val assetManifestVersion: Int,
    val requestByteCount: Long,
    val requestSHA256: String,
    val assetManifestByteCount: Long,
    val assetManifestSHA256: String,
)
data class DecodedJournal(val snapshot: JournalSnapshot, val binding: JournalBinding)

/** Strict production codec for governed package bytes. */
object CapturePackageCodec {
    private val json = Json { isLenient = false; ignoreUnknownKeys = false; allowSpecialFloatingPointValues = false }

    fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    fun canonical(element: JsonElement): ByteArray = (canonicalText(element, 0) + "\n").toByteArray(Charsets.UTF_8)

    fun parseCanonical(bytes: ByteArray): JsonObject {
        if (bytes.isEmpty() || bytes.size > CONTROL_LIMIT_BYTES) fail("controlBounds")
        if (bytes.last() != '\n'.code.toByte()) fail("nonCanonical")
        val element = try { json.parseToJsonElement(bytes.toString(Charsets.UTF_8)) } catch (_: Exception) { fail("malformedJson") }
        if (element !is JsonObject || !canonical(element).contentEquals(bytes)) fail("nonCanonical")
        return element
    }

    fun encodeAssets(value: AssetManifest): ByteArray {
        requireUUID(value.requestID)
        return canonical(JsonObject(sortedMapOf("assetCount" to JsonPrimitive(0), "assets" to JsonArray(emptyList()), "requestID" to JsonPrimitive(value.requestID), "schemaVersion" to JsonPrimitive(1))))
    }

    fun decodeAssets(bytes: ByteArray): AssetManifest {
        val obj = parseCanonical(bytes); exactKeys(obj, setOf("assetCount", "assets", "requestID", "schemaVersion"))
        if (integer(obj, "schemaVersion") != 1L || integer(obj, "assetCount") != 0L || array(obj, "assets").isNotEmpty()) fail("assetManifestProfile")
        return AssetManifest(string(obj, "requestID").also(::requireUUID))
    }

    fun encodeJournal(snapshot: JournalSnapshot, requestBytes: ByteArray, assetBytes: ByteArray): ByteArray {
        requireUUID(snapshot.requestID)
        if (snapshot.events.isEmpty() || snapshot.events.size > JOURNAL_EVENT_LIMIT) fail("eventBounds")
        var replay: JournalSnapshot? = null
        snapshot.events.forEach { event -> replay = when (val result = CaptureJournalReducer.reduce(snapshot.requestID, replay, event)) {
            is JournalReduction.Accepted -> result.snapshot
            is JournalReduction.Rejected -> fail("journal.${result.reason}")
        } }
        if (replay != snapshot) fail("snapshotFrontierMismatch")
        return canonical(JsonObject(sortedMapOf(
            "assetManifestByteCount" to JsonPrimitive(assetBytes.size), "assetManifestSHA256" to JsonPrimitive(sha256(assetBytes)), "assetManifestVersion" to JsonPrimitive(1),
            "events" to JsonArray(snapshot.events.map(::eventJson)), "journalVersion" to JsonPrimitive(1), "packageVersion" to JsonPrimitive(1),
            "requestByteCount" to JsonPrimitive(requestBytes.size), "requestID" to JsonPrimitive(snapshot.requestID), "requestSHA256" to JsonPrimitive(sha256(requestBytes)), "requestContractVersion" to JsonPrimitive(1),
        )))
    }

    fun decodeJournal(bytes: ByteArray): DecodedJournal {
        val obj = parseCanonical(bytes)
        exactKeys(obj, setOf("assetManifestByteCount", "assetManifestSHA256", "assetManifestVersion", "events", "journalVersion", "packageVersion", "requestByteCount", "requestID", "requestSHA256", "requestContractVersion"))
        if (integer(obj, "journalVersion") != 1L) fail("journalVersion")
        val binding = JournalBinding(integer(obj, "packageVersion").toInt(), integer(obj, "requestContractVersion").toInt(), integer(obj, "assetManifestVersion").toInt(), integer(obj, "requestByteCount"), string(obj, "requestSHA256"), integer(obj, "assetManifestByteCount"), string(obj, "assetManifestSHA256"))
        if (binding.packageVersion != 1 || binding.requestContractVersion != 1 || binding.assetManifestVersion != 1) fail("bindingVersion")
        if (binding.requestByteCount !in 1..CONTROL_LIMIT_BYTES.toLong() || binding.assetManifestByteCount !in 1..CONTROL_LIMIT_BYTES.toLong()) fail("bindingBounds")
        requireSha(binding.requestSHA256); requireSha(binding.assetManifestSHA256)
        val requestID = string(obj, "requestID").also(::requireUUID)
        val encodedEvents = array(obj, "events")
        if (encodedEvents.isEmpty() || encodedEvents.size > JOURNAL_EVENT_LIMIT) fail("eventBounds")
        var snapshot: JournalSnapshot? = null
        encodedEvents.forEach { encoded ->
            val event = decodeEvent(encoded as? JsonObject ?: fail("eventShape"))
            snapshot = when (val reduced = CaptureJournalReducer.reduce(requestID, snapshot, event)) {
                is JournalReduction.Accepted -> reduced.snapshot
                is JournalReduction.Rejected -> fail("journal.${reduced.reason}")
            }
        }
        return DecodedJournal(snapshot!!, binding)
    }

    /** Full v1 validation followed by the narrower current M3 admission profile. */
    fun admitRequest(bytes: ByteArray): AdmittedRequest = decodeRequest(bytes, gateCurrentCore = true)

    /** Historical package decoding validates v1 bytes without comparing an old pin to today's core build. */
    fun decodeHistoricalRequest(bytes: ByteArray): AdmittedRequest = decodeRequest(bytes, gateCurrentCore = false)

    private fun decodeRequest(bytes: ByteArray, gateCurrentCore: Boolean): AdmittedRequest {
        val obj = parseCanonical(bytes)
        exactKeys(obj, setOf("calendar", "captureSource", "contractVersion", "createdAtEpochMilliseconds", "invocation", "locale", "operation", "payloads", "pins", "preset", "requestID", "timezone"))
        if (integer(obj, "contractVersion") != 1L) fail("requestContractVersion")
        val requestID = string(obj, "requestID").also(::requireUUID)
        val source = boundedString(obj, "captureSource", 1, 16)
        val calendar = boundedString(obj, "calendar", 1, 32)
        val operation = boundedString(obj, "operation", 1, 32)
        val created = integer(obj, "createdAtEpochMilliseconds")
        if (created !in 0..4_102_444_800_000L) fail("requestBounds")
        val timezone = boundedString(obj, "timezone", 1, 64)
        try { ZoneId.of(timezone) } catch (_: DateTimeException) { fail("timezone") }
        boundedString(obj, "locale", 2, 35)

        val invocation = objectValue(obj, "invocation"); exactKeys(invocation, setOf("locationOutcome", "originRecordingID", "sequence"))
        val location = boundedString(invocation, "locationOutcome", 1, 32)
        val origin = invocation["originRecordingID"]
        if (origin !is JsonNull) requireUUID(string(invocation, "originRecordingID"))
        val sequence = integer(invocation, "sequence"); if (sequence < 0) fail("invocationBounds")
        if (location !in setOf("notRequested", "unavailable", "coordinatesFrozen", "labelFrozen")) fail("invocationEnum")

        val payloads = array(obj, "payloads"); if (payloads.size !in 1..128) fail("payloadBounds")
        val ids = mutableSetOf<String>()
        payloads.forEach { raw ->
            val payload = raw as? JsonObject ?: fail("payloadShape")
            when (string(payload, "kind")) {
                "text" -> { exactKeys(payload, setOf("id", "kind", "text")); boundedString(payload, "text", 0, 65_536) }
                "link" -> { exactKeys(payload, setOf("id", "kind", "label", "url")); boundedString(payload, "label", 0, 4_096); val url = boundedString(payload, "url", 1, 8_192); if (!url.startsWith("http://") && !url.startsWith("https://")) fail("linkUrl") }
                "asset" -> { // Validate the complete tagged shape before the M3 profile rejects it.
                    exactKeys(payload, setOf("id", "kind", "length", "mediaType", "originalNamePolicy", "safeExtension", "sha256", "sourceID"))
                    requireUUID(string(payload, "sourceID")); boundedString(payload, "mediaType", 1, 127)
                    if (integer(payload, "length") !in 0..1_073_741_824L) fail("assetBounds")
                    requireSha(string(payload, "sha256")); val ext = boundedString(payload, "safeExtension", 0, 16)
                    if (!Regex("^[a-z0-9]*$").matches(ext) || string(payload, "originalNamePolicy") !in setOf("discard", "safeStem")) fail("assetShape")
                }
                else -> fail("payloadKind")
            }
            if (!ids.add(string(payload, "id").also(::requireUUID))) fail("duplicatePayload")
        }

        val pins = objectValue(obj, "pins"); exactKeys(pins, setOf("coreVersion", "modelProfileID", "modelRevision", "profileID", "profileVersion", "rendererRevision"))
        val core = boundedString(pins, "coreVersion", 1, 64); val renderer = boundedString(pins, "rendererRevision", 1, 64); val profile = boundedString(pins, "profileID", 1, 64)
        val profileVersion = integer(pins, "profileVersion"); if (profileVersion !in 1..Int.MAX_VALUE.toLong()) fail("pinBounds")
        for (key in listOf("modelProfileID", "modelRevision")) if (pins[key] !is JsonNull) boundedString(pins, key, 1, 64)

        val preset = objectValue(obj, "preset"); exactKeys(preset, setOf("destinationPolicy", "id", "metadataPolicy", "retryMarkerPolicy", "revision", "routePolicy", "snapshotHash", "templateFreezePoint"))
        val presetID = string(preset, "id").also(::requireUUID); if (integer(preset, "revision") < 0) fail("presetBounds")
        val snapshotHash = string(preset, "snapshotHash").also(::requireSha)
        val zeroed = JsonObject(preset.toMutableMap().also { it["snapshotHash"] = JsonPrimitive(ZERO_SHA) })
        if (sha256(canonical(zeroed)) != snapshotHash) fail("presetSnapshotHash")
        if (string(preset, "templateFreezePoint") != "firstPreparation" || string(preset, "retryMarkerPolicy") !in setOf("none", "voxCaptureCommentV1")) fail("presetEnum")

        val route = objectValue(preset, "routePolicy"); exactKeys(route, setOf("attachmentFolder", "collisionPolicy", "extensionPolicy", "logicalFolder", "noteNameTemplate"))
        boundedString(route, "noteNameTemplate", 1, 1024); validateSegments(array(route, "logicalFolder"), allow32 = false); validateSegments(array(route, "attachmentFolder"), allow32 = true)
        if (string(route, "extensionPolicy") != "markdownDotMd" || string(route, "collisionPolicy") !in setOf("fail", "reuseIfHashMatches", "deterministicSuffix")) fail("routeEnum")

        val metadata = objectValue(preset, "metadataPolicy"); exactKeys(metadata, setOf("finalNewline", "frontmatterMode", "lineEnding", "orderedFields", "templatePolicy"))
        boolean(metadata, "finalNewline")
        if (string(metadata, "frontmatterMode") !in setOf("none", "merge", "replace") || string(metadata, "templatePolicy") !in setOf("none", "frozenObservation") || string(metadata, "lineEnding") !in setOf("lf", "preserveExisting")) fail("metadataEnum")
        val fields = array(metadata, "orderedFields"); if (fields.size > 128) fail("metadataBounds")
        val names = mutableSetOf<String>(); fields.forEach { raw -> val field = raw as? JsonObject ?: fail("fieldType"); exactKeys(field, setOf("name", "value")); val name = boundedString(field, "name", 1, 128); boundedString(field, "value", 0, 8192); if ('\n' in name || '\r' in name || !names.add(name)) fail("metadataField") }

        val destination = objectValue(preset, "destinationPolicy"); exactKeys(destination, setOf("capabilityClass", "capabilityReference", "expectedCaseSensitivity"))
        boundedString(destination, "capabilityReference", 1, 128)
        if (string(destination, "capabilityClass") !in setOf("userVault", "recordingExport") || string(destination, "expectedCaseSensitivity") !in setOf("unknown", "sensitive", "insensitive")) fail("destinationEnum")

        // Current enqueue profile. Case sensitivity must have been observed by native storage discovery.
        if (source != "app" || calendar != "gregorian" || operation != "newNote" || payloads.size !in 1..2 || payloads.any { string(it as JsonObject, "kind") !in setOf("text", "link") }) fail("requestProfile")
        if (location != "notRequested" || origin !is JsonNull) fail("invocationProfile")
        if (pins["modelProfileID"] !is JsonNull || pins["modelRevision"] !is JsonNull || renderer != CURRENT_RENDERER || profile != CURRENT_PROFILE || profileVersion != 1L || (gateCurrentCore && core != CURRENT_CORE)) fail("pinProfile")
        if (presetID != FIXED_M3_PRESET_ID || integer(preset, "revision") != 1L || string(preset, "retryMarkerPolicy") != "none") fail("presetProfile")
        if (string(route, "collisionPolicy") != "deterministicSuffix" || array(route, "attachmentFolder").isNotEmpty() || array(route, "logicalFolder").map { (it as JsonPrimitive).content } != listOf("Inbox") || string(route, "noteNameTemplate") != "capture-{id}.md") fail("routeProfile")
        if (string(metadata, "frontmatterMode") != "none" || string(metadata, "templatePolicy") != "none" || string(metadata, "lineEnding") != "lf" || !boolean(metadata, "finalNewline") || fields.isNotEmpty()) fail("metadataProfile")
        if (string(destination, "capabilityClass") != "userVault" || string(destination, "expectedCaseSensitivity") != "sensitive") fail("destinationProfile")
        return AdmittedRequest(requestID, created)
    }

    fun verifyBinding(decoded: DecodedJournal, requestBytes: ByteArray, assetBytes: ByteArray) {
        val b = decoded.binding
        if (b.requestByteCount != requestBytes.size.toLong() || b.assetManifestByteCount != assetBytes.size.toLong() || b.requestSHA256 != sha256(requestBytes) || b.assetManifestSHA256 != sha256(assetBytes)) fail("journalBindingMismatch")
    }

    private fun validateSegments(value: JsonArray, allow32: Boolean) {
        val maximum = if (allow32) 32 else 31; if (value.size > maximum) fail("pathBounds")
        value.forEach { raw -> val segment = (raw as? JsonPrimitive)?.takeIf { it.isString }?.content ?: fail("fieldType"); if (codePoints(segment) !in 1..255 || segment in setOf(".", "..") || segment.any { it == '/' || it == '\\' || it == '\u0000' }) fail("unsafePath") }
    }
    private fun eventJson(event: JournalEvent) = JsonObject(sortedMapOf("code" to JsonPrimitive(event.code.wire()), "fromState" to (event.fromState?.let { JsonPrimitive(it.wire()) } ?: JsonNull), "occurredAtEpochMillis" to JsonPrimitive(event.occurredAtEpochMillis), "receiptID" to (event.receiptID?.let { JsonPrimitive(it) } ?: JsonNull), "resumeState" to (event.resumeState?.let { JsonPrimitive(it.wire()) } ?: JsonNull), "revision" to JsonPrimitive(event.revision), "state" to JsonPrimitive(event.state.wire())))
    private fun decodeEvent(obj: JsonObject): JournalEvent {
        exactKeys(obj, setOf("code", "fromState", "occurredAtEpochMillis", "receiptID", "resumeState", "revision", "state"))
        fun optionalState(key: String): CaptureState? = if (obj[key] is JsonNull) null else state(string(obj, key))
        fun optionalUUID(key: String): String? = if (obj[key] is JsonNull) null else string(obj, key).also(::requireUUID)
        val revision = integer(obj, "revision")
        if (revision !in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) fail("revisionBounds")
        return JournalEvent(revision.toInt(), optionalState("fromState"), state(string(obj, "state")), code(string(obj, "code")), integer(obj, "occurredAtEpochMillis"), optionalState("resumeState"), optionalUUID("receiptID"))
    }
    private fun exactKeys(obj: JsonObject, expected: Set<String>) { if (obj.keys != expected) fail("unknownOrMissingField") }
    private fun string(obj: JsonObject, key: String) = (obj[key] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: fail("fieldType")
    private fun boundedString(obj: JsonObject, key: String, min: Int, max: Int): String = string(obj, key).also { if (codePoints(it) !in min..max) fail("stringBounds") }
    private fun codePoints(value: String) = value.codePointCount(0, value.length)
    private fun integer(obj: JsonObject, key: String) = (obj[key] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull ?: fail("fieldType")
    private fun boolean(obj: JsonObject, key: String) = (obj[key] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull ?: fail("fieldType")
    private fun array(obj: JsonObject, key: String) = obj[key] as? JsonArray ?: fail("fieldType")
    private fun objectValue(obj: JsonObject, key: String) = obj[key] as? JsonObject ?: fail("fieldType")
    private fun requireUUID(value: String) { if (!UUID_PATTERN.matches(value)) fail("uuid") }
    private fun requireSha(value: String) { if (!SHA_PATTERN.matches(value)) fail("sha256") }
    private fun state(value: String) = CaptureState.entries.firstOrNull { it.wire() == value } ?: fail("state")
    private fun code(value: String) = JournalCode.entries.firstOrNull { it.wire() == value } ?: fail("code")
    private fun fail(code: String): Nothing = throw PackageCodecException(code)
    private fun canonicalText(value: JsonElement, depth: Int): String = when (value) { is JsonObject -> if (value.isEmpty()) "{}" else value.entries.sortedBy { it.key }.joinToString(",\n", "{\n", "\n${"  ".repeat(depth)}}") { (key, item) -> "${"  ".repeat(depth + 1)}${quote(key)}: ${canonicalText(item, depth + 1)}" }; is JsonArray -> if (value.isEmpty()) "[]" else value.joinToString(",\n", "[\n", "\n${"  ".repeat(depth)}]") { "${"  ".repeat(depth + 1)}${canonicalText(it, depth + 1)}" }; is JsonNull -> "null"; is JsonPrimitive -> if (value.isString) quote(value.content) else value.content }
    private fun quote(value: String): String = buildString { append('"'); value.forEach { c -> when (c) { '"' -> append("\\\""); '\\' -> append("\\\\"); '\b' -> append("\\b"); '\u000C' -> append("\\f"); '\n' -> append("\\n"); '\r' -> append("\\r"); '\t' -> append("\\t"); else -> if (c.code < 0x20) append("\\u%04x".format(c.code)) else append(c) } }; append('"') }
}

internal fun CaptureState.wire() = name.lowercase().replace(Regex("_([a-z])")) { it.groupValues[1].uppercase() }
internal fun JournalCode.wire() = name.lowercase().replace(Regex("_([a-z])")) { it.groupValues[1].uppercase() }
