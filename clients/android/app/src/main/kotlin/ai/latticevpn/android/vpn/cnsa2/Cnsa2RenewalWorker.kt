package ai.latticevpn.android.vpn.cnsa2

import ai.latticevpn.android.data.AccountClient
import ai.latticevpn.android.data.AccountException
import ai.latticevpn.android.data.AccountStore
import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * Once a day, renews the device's CNSA 2.0 certificate if it is inside the
 * renewal window (the last 10 of its 30 days) or already expired. Runs whether
 * or not the app is open, so a phone that stays connected for weeks never
 * reaches expiry. The key does not change; only the certificate is replaced,
 * and the tunnel picks the new one up at its next connection.
 */
class Cnsa2RenewalWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val context = applicationContext
        val enroller = Cnsa2Enroller(context, AccountClient(context))
        if (!enroller.renewalDue()) return Result.success()
        val number = AccountStore(context).accountNumber() ?: return Result.success()
        return try {
            val renewed = enroller.renewIfDue(number)
            Log.i(TAG, if (renewed) "certificate renewed" else "certificate already current")
            Result.success()
        } catch (e: AccountException) {
            if (e.kind == AccountException.Kind.NETWORK) {
                Result.retry()
            } else {
                // Signed out, subscription lapsed, device limit: nothing a retry can fix. Tomorrow's run tries again.
                Log.w(TAG, "renewal refused: ${e.message}")
                Result.success()
            }
        } catch (e: Exception) {
            Log.w(TAG, "renewal failed: ${e.message}")
            Result.success()
        }
    }

    companion object {
        private const val TAG = "LatticeCNSA2"
        const val WORK_NAME = "cnsa2-certificate-renewal"

        /** Safe to call on every app start; an existing schedule is kept. */
        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<Cnsa2RenewalWorker>(24, TimeUnit.HOURS)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context.applicationContext)
                .enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}
