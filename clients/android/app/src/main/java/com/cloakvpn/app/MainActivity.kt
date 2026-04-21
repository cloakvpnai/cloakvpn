package com.cloakvpn.app

import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import com.cloakvpn.app.ui.CloakApp
import com.cloakvpn.app.vpn.TunnelRepository

class MainActivity : ComponentActivity() {

    private val prepareVpn = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == RESULT_OK) {
            TunnelRepository.get(this).connect()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            CloakApp(
                onConnect = {
                    val intent = VpnService.prepare(this)
                    if (intent != null) prepareVpn.launch(intent)
                    else TunnelRepository.get(this).connect()
                },
                onDisconnect = { TunnelRepository.get(this).disconnect() }
            )
        }
    }
}
