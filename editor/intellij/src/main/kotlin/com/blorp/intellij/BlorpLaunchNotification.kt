package com.blorp.intellij

import com.intellij.notification.NotificationAction
import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.options.ShowSettingsUtil
import com.intellij.openapi.project.Project

internal const val BLORP_NOTIFICATION_GROUP = "Blorp"

/** The platform only logs a failed server start; this makes the failure and its fix visible. */
internal fun notifyLaunchFailed(project: Project, problem: String) {
    NotificationGroupManager.getInstance()
        .getNotificationGroup(BLORP_NOTIFICATION_GROUP)
        .createNotification("The Blorp language server did not start", problem, NotificationType.ERROR)
        .addAction(
            NotificationAction.createSimpleExpiring("Open Blorp settings") {
                ShowSettingsUtil.getInstance().showSettingsDialog(project, BlorpConfigurable::class.java)
            }
        )
        .notify(project)
}
