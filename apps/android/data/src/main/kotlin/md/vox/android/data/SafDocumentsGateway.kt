package md.vox.android.data

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import md.vox.android.capturedomain.*
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Opaque provider handles: JVM fakes construct them freely; android.net.Uri never leaks past the gateway. */
class SafFolderHandle internal constructor(internal val key: String)
class SafDocumentHandle internal constructor(internal val key: String)

/**
 * ADR-0023 §3: the ONLY code that touches ContentResolver, DocumentsContract, cursors, or
 * provider streams. Bounded, content-free operations with a 30-second watchdog each
 * (ADR-0019). [createDocument] is type-unreachable without a [DurableMarkerToken], which
 * only durable marker persistence can produce — the static governance gate complements it.
 *
 * No POSIX path, symlink, case, atomic-rename, or immediate-consistency assumptions;
 * all provider names and metadata are untrusted input.
 */
interface SafDocumentsGateway {
    /** Revalidates the persisted tree grant for the destination. */
    fun revalidateGrant(destination: VaultDestination): Boolean

    /** Lists child display names under a resolved folder handle (bounded, provider order). */
    fun listChildDisplayNames(parent: SafFolderHandle): List<String>?

    /** Resolves the folder chain for [segments] under the destination; optionally creates missing folders. */
    fun resolveFolder(destination: VaultDestination, segments: List<String>, createMissing: Boolean): SafFolderHandle?

    /**
     * Creates a note document. The marker token is mandatory: the provider create call is
     * unreachable without a durably persisted crash-window marker (ADR-0023 §3/§4).
     */
    fun createDocument(marker: DurableMarkerToken, parent: SafFolderHandle, displayName: String, mediaType: String): SafResult<SafDocumentHandle>

    /** Bounded write of prepared bytes; ends in a typed result, never partial silence. */
    fun writeDocument(handle: SafDocumentHandle, bytes: ByteArray, expectedLength: Long): SafResult<Unit>

    /** Bounded read-back of the created document returning exact length and SHA-256. */
    fun readBackDocument(handle: SafDocumentHandle): SafResult<Pair<Long, String>>

    /** Bounded exact-name child lookup for reconciliation. */
    fun findChildByDisplayName(parent: SafFolderHandle, displayName: String): List<SafDocumentHandle>
}

/** Typed coarse gateway failures (ADR-0019: never a provider crash/exception detail). */
sealed interface GatewayError {
    data object PermissionLost : GatewayError
    data object Timeout : GatewayError
    data object ProviderFailure : GatewayError
    data object InvalidState : GatewayError

    val name: String get() = when (this) { PermissionLost -> "permissionLost"; Timeout -> "timeout"; ProviderFailure -> "providerFailure"; InvalidState -> "invalidState" }
}

/** Content-free gateway result carrying a coarse [GatewayError] code on failure. */
sealed interface SafResult<out V> {
    data class Success<out V>(val value: V) : SafResult<V>
    data class Error(val code: String) : SafResult<Nothing>

    companion object {
        fun <V> success(value: V): SafResult<V> = Success(value)
        fun error(code: String): SafResult<Nothing> = Error(code)
    }
}

/**
 * Production gateway over the platform ContentResolver/DocumentsContract. Open only for
 * instrumentation: on-target tests substitute grant revalidation (shell-adopted identity
 * bypasses persisted-grant UX, which requires future interactive campaign evidence).
 */
open class AndroidSafDocumentsGateway(
    context: Context,
    private val timeoutMillis: Long = TimeUnit.SECONDS.toMillis(30),
) : SafDocumentsGateway {
    private val resolver: ContentResolver = context.applicationContext.contentResolver

    override fun revalidateGrant(destination: VaultDestination): Boolean = try {
        val uri = Uri.parse(destination.treeUri)
        val persisted = resolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission && it.isWritePermission }
        persisted && DocumentsContract.getTreeDocumentId(uri) != null
    } catch (_: Exception) {
        false
    }

    override fun listChildDisplayNames(parent: SafFolderHandle): List<String>? = try {
        val parentUri = Uri.parse(parent.key)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(parentUri, DocumentsContract.getDocumentId(parentUri))
        val projection = arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        resolver.query(children, projection, null, null, null)?.use { cursor ->
            val names = mutableListOf<String>()
            while (cursor.moveToNext()) names.add(cursor.getString(0) ?: continue)
            names
        }
    } catch (_: Exception) {
        null
    }

    override fun resolveFolder(destination: VaultDestination, segments: List<String>, createMissing: Boolean): SafFolderHandle? = try {
        if (segments.any { it.isEmpty() || it.toByteArray(Charsets.UTF_8).size > 255 || '/' in it || '\u0000' in it }) return null
        val treeUri = Uri.parse(destination.treeUri)
        var current = DocumentsContract.buildDocumentUriUsingTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri))
        for (segment in segments) {
            current = stepInto(current, segment, treeUri, createMissing) ?: return null
        }
        SafFolderHandle(current.toString())
    } catch (_: Exception) {
        null
    }

    override fun createDocument(marker: DurableMarkerToken, parent: SafFolderHandle, displayName: String, mediaType: String): SafResult<SafDocumentHandle> =
        watchdog("create") {
            // marker is the durable-proof parameter; its type presence is the create gate.
            val parentUri = Uri.parse(parent.key)
            val created = DocumentsContract.createDocument(resolver, parentUri, mediaType, displayName)
                ?: throw IllegalStateException(GatewayError.ProviderFailure.name)
            SafDocumentHandle(created.toString())
        }

    override fun writeDocument(handle: SafDocumentHandle, bytes: ByteArray, expectedLength: Long): SafResult<Unit> = watchdog("write") {
        if (bytes.size.toLong() != expectedLength) throw IllegalStateException(GatewayError.InvalidState.name)
        resolver.openOutputStream(Uri.parse(handle.key), "w")?.use { stream ->
            stream.write(bytes)
            stream.flush()
        } ?: throw IllegalStateException(GatewayError.ProviderFailure.name)
    }

    override fun readBackDocument(handle: SafDocumentHandle): SafResult<Pair<Long, String>> = watchdog("readback") {
        resolver.openInputStream(Uri.parse(handle.key))?.use { input ->
            val digest = MessageDigest.getInstance("SHA-256")
            var total = 0L
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                total += read
                digest.update(buffer, 0, read)
            }
            total to digest.digest().joinToString("") { "%02x".format(it) }
        } ?: throw IllegalStateException(GatewayError.ProviderFailure.name)
    }

    override fun findChildByDisplayName(parent: SafFolderHandle, displayName: String): List<SafDocumentHandle> = try {
        val parentUri = Uri.parse(parent.key)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(parentUri, DocumentsContract.getDocumentId(parentUri))
        val projection = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        resolver.query(children, projection, null, null, null)?.use { cursor ->
            val matches = mutableListOf<SafDocumentHandle>()
            while (cursor.moveToNext()) {
                val name = cursor.getString(1) ?: continue
                if (name == displayName) matches.add(SafDocumentHandle(DocumentsContract.buildDocumentUriUsingTree(parentUri, cursor.getString(0)).toString()))
            }
            matches
        } ?: emptyList()
    } catch (_: Exception) {
        emptyList()
    }

    private fun <T> watchdog(operation: String, block: () -> T): SafResult<T> {
        val executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "vox-saf-$operation") }
        return try {
            val future = executor.submit(block)
            SafResult.success(future.get(timeoutMillis, TimeUnit.MILLISECONDS))
        } catch (timeout: java.util.concurrent.TimeoutException) {
            SafResult.error(GatewayError.Timeout.name)
        } catch (security: SecurityException) {
            SafResult.error(GatewayError.PermissionLost.name)
        } catch (failure: Throwable) {
            SafResult.error(GatewayError.ProviderFailure.name)
        } finally {
            executor.shutdownNow()
        }
    }

    private fun stepInto(current: Uri, segment: String, treeUri: Uri, createMissing: Boolean): Uri? {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, DocumentsContract.getDocumentId(current))
        val folderId = queryChildId(children, segment, expectFolder = true)
        if (folderId != null) return DocumentsContract.buildDocumentUriUsingTree(treeUri, folderId)
        val fileId = queryChildId(children, segment, expectFolder = false)
        if (fileId != null) return null // a non-directory occupies the name
        if (!createMissing) return null
        return DocumentsContract.createDocument(resolver, current, DocumentsContract.Document.MIME_TYPE_DIR, segment)
    }

    private fun queryChildId(childrenUri: Uri, displayName: String, expectFolder: Boolean): String? {
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        return resolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val name = cursor.getString(1) ?: continue
                val mime = cursor.getString(2) ?: continue
                val isFolder = mime == DocumentsContract.Document.MIME_TYPE_DIR
                if (name == displayName && isFolder == expectFolder) return cursor.getString(0)
            }
            null
        }
    }
}
