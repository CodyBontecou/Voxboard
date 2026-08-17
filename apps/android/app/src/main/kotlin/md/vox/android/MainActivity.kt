package md.vox.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = (application as VoxApplication).compositionRoot
        setContent {
            MaterialTheme {
                VoxFoundationShell(root)
            }
        }
    }
}

private enum class Destination(val route: String, val label: String) {
    Onboarding("onboarding", "Onboarding"),
    Vault("vault", "Vault setup"),
    Capture("capture", "Quick Capture"),
    Inbox("inbox", "Inbox"),
    History("history", "History"),
}

@Composable
private fun VoxFoundationShell(root: AppCompositionRoot) {
    val navController = rememberNavController()
    val backStack by navController.currentBackStackEntryAsState()
    val currentRoute = backStack?.destination?.route
    val primary = listOf(Destination.Capture, Destination.Inbox, Destination.History)

    Scaffold(
        bottomBar = {
            if (currentRoute in primary.map { it.route }) {
                NavigationBar {
                    primary.forEach { destination ->
                        NavigationBarItem(
                            selected = currentRoute == destination.route,
                            onClick = {
                                navController.navigate(destination.route) {
                                    popUpTo(navController.graph.findStartDestination().id) {
                                        saveState = true
                                    }
                                    launchSingleTop = true
                                    restoreState = true
                                }
                            },
                            icon = { Text("•") },
                            label = { Text(destination.label) },
                        )
                    }
                }
            }
        },
    ) { padding ->
        NavHost(
            navController = navController,
            startDestination = Destination.Onboarding.route,
            modifier = Modifier.padding(padding),
        ) {
            composable(Destination.Onboarding.route) {
                FoundationPage(
                    title = "Welcome to Vox.md",
                    detail = "This Phase 1 shell is local-only in intent. Capture and durable storage are not implemented.",
                    actionLabel = "Review vault setup",
                    onAction = { navController.navigate(Destination.Vault.route) },
                )
            }
            composable(Destination.Vault.route) {
                FoundationPage(
                    title = "Vault setup unavailable",
                    detail = "SAF selection, persisted grants, permission repair, and delivery are not implemented.",
                    actionLabel = "Open Quick Capture placeholder",
                    onAction = { navController.navigate(Destination.Capture.route) },
                )
            }
            composable(Destination.Capture.route) {
                FoundationPage(
                    title = "Quick Capture unavailable",
                    detail = "Text/link capture, local durability, Rust materialization, quota, and vault delivery are not implemented. Core: ${root.captureFoundation.coreBridge.availability}.",
                )
            }
            composable(Destination.Inbox.route) {
                FoundationPage(
                    title = "Inbox unavailable",
                    detail = "No durable packages, jobs, retries, or provider status exist in this foundation.",
                )
            }
            composable(Destination.History.route) {
                FoundationPage(
                    title = "History unavailable",
                    detail = "No captures or completion tombstones are recorded by this foundation.",
                )
            }
        }
    }
}

@Composable
private fun FoundationPage(
    title: String,
    detail: String,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(PaddingValues(24.dp)),
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(title, style = MaterialTheme.typography.headlineSmall)
        Text(detail, style = MaterialTheme.typography.bodyLarge)
        if (actionLabel != null && onAction != null) {
            Button(onClick = onAction) {
                Text(actionLabel)
            }
        }
    }
}
