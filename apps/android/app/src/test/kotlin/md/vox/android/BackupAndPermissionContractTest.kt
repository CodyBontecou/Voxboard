package md.vox.android

import java.nio.file.Files
import java.nio.file.Path
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Document
import org.w3c.dom.Element

class BackupAndPermissionContractTest {
    private val expectedDomains = setOf(
        "root",
        "file",
        "database",
        "sharedpref",
        "external",
        "device_root",
        "device_file",
        "device_database",
        "device_sharedpref",
    )

    @Test
    fun manifestDisablesBackupAndReferencesBothDefenseInDepthRules() {
        val document = parse(mainSource.resolve("AndroidManifest.xml"))
        val application = document.getElementsByTagName("application").item(0) as Element

        assertEquals("false", application.androidAttribute("allowBackup"))
        assertEquals("@xml/backup_rules", application.androidAttribute("fullBackupContent"))
        assertEquals("@xml/data_extraction_rules", application.androidAttribute("dataExtractionRules"))
    }

    @Test
    fun legacyRulesExcludeEveryStorageDomainAtItsRoot() {
        val document = parse(mainSource.resolve("res/xml/backup_rules.xml"))
        assertEquals("full-backup-content", document.documentElement.tagName)
        assertEquals(expectedDomains, excludedDomains(document.documentElement))
    }

    @Test
    fun modernRulesExcludeEveryStorageDomainFromCloudAndTransfer() {
        val document = parse(mainSource.resolve("res/xml/data_extraction_rules.xml"))
        val cloud = document.getElementsByTagName("cloud-backup").item(0) as? Element
        val transfer = document.getElementsByTagName("device-transfer").item(0) as? Element

        assertNotNull(cloud)
        assertNotNull(transfer)
        assertEquals(expectedDomains, excludedDomains(requireNotNull(cloud)))
        assertEquals(expectedDomains, excludedDomains(requireNotNull(transfer)))
    }

    @Test
    fun manifestContainsNoForbiddenOrUnexpectedPermissions() {
        val document = parse(mainSource.resolve("AndroidManifest.xml"))
        val permissionNodes = document.getElementsByTagName("uses-permission")
        val declared = (0 until permissionNodes.length).map { index ->
            (permissionNodes.item(index) as Element).androidAttribute("name")
        }.toSet()
        val forbidden = setOf(
            "android.permission.INTERNET",
            "android.permission.RECORD_AUDIO",
            "android.permission.ACCESS_COARSE_LOCATION",
            "android.permission.ACCESS_FINE_LOCATION",
            "android.permission.MANAGE_EXTERNAL_STORAGE",
            "android.permission.READ_EXTERNAL_STORAGE",
            "android.permission.WRITE_EXTERNAL_STORAGE",
            "android.permission.READ_MEDIA_AUDIO",
            "android.permission.READ_MEDIA_IMAGES",
            "android.permission.READ_MEDIA_VIDEO",
        )

        assertTrue("No permission is required by the Phase 1 shell", declared.isEmpty())
        assertFalse("Forbidden permissions present: ${declared.intersect(forbidden)}", declared.any(forbidden::contains))
    }

    private fun excludedDomains(parent: Element): Set<String> {
        val excludes = parent.getElementsByTagName("exclude")
        return (0 until excludes.length).map { index ->
            val element = excludes.item(index) as Element
            assertEquals(".", element.getAttribute("path"))
            element.getAttribute("domain")
        }.toSet()
    }

    private fun parse(path: Path): Document {
        assertTrue("Missing contract input: $path", Files.isRegularFile(path))
        val factory = DocumentBuilderFactory.newInstance()
        factory.isNamespaceAware = true
        factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
        factory.setFeature("http://xml.org/sax/features/external-general-entities", false)
        factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false)
        factory.setAttribute("http://javax.xml.XMLConstants/property/accessExternalDTD", "")
        factory.setAttribute("http://javax.xml.XMLConstants/property/accessExternalSchema", "")
        return factory.newDocumentBuilder().parse(path.toFile())
    }

    private fun Element.androidAttribute(name: String): String =
        getAttributeNS("http://schemas.android.com/apk/res/android", name)

    private val mainSource: Path
        get() {
            val working = Path.of(System.getProperty("user.dir"))
            val fromRoot = working.resolve("app/src/main")
            return if (Files.isDirectory(fromRoot)) fromRoot else working.resolve("src/main")
        }
}
