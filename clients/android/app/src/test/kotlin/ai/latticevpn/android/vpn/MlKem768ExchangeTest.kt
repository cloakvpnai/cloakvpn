package ai.latticevpn.android.vpn

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import java.util.Base64

/**
 * Interop with the Go concentrator. The vector below was produced by the
 * real server function (mlkem768Respond in server/api/internal/wg/mlkem.go)
 * for the key pair derived from SEED, so this test fails if the Android
 * derivation ever drifts from what the regions install.
 */
class MlKem768ExchangeTest {

    private val seed = ByteArray(64) { (it * 7 + 3).toByte() }
    private val clientWg = Base64.getEncoder().encodeToString(ByteArray(32) { (0x10 + it).toByte() })
    private val serverWg = Base64.getEncoder().encodeToString(ByteArray(32) { (0xA0 + it).toByte() })

    @Test
    fun publicKeyMatchesGo() {
        assertEquals(GO_ENCAPSULATION_KEY, MlKem768Exchange.fromSeed(seed).publicKeyB64)
    }

    @Test
    fun derivesTheSamePresharedKeyAsTheServer() {
        val psk = MlKem768Exchange.fromSeed(seed).presharedKey(GO_CIPHERTEXT, clientWg, serverWg)
        assertArrayEquals(Base64.getDecoder().decode(GO_PSK), psk)
    }

    @Test
    fun keyIsBoundToBothWireGuardKeys() {
        val swapped = MlKem768Exchange.fromSeed(seed).presharedKey(GO_CIPHERTEXT, serverWg, clientWg)
        assertFalse(Base64.getDecoder().decode(GO_PSK).contentEquals(swapped))
    }

    @Test
    fun freshKeyPairsHaveTheRightSizeAndDiffer() {
        val a = MlKem768Exchange()
        val b = MlKem768Exchange()
        assertEquals(1184, Base64.getDecoder().decode(a.publicKeyB64).size)
        assertFalse(a.publicKeyB64 == b.publicKeyB64)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsShortCiphertext() {
        MlKem768Exchange().presharedKey(Base64.getEncoder().encodeToString(ByteArray(100)), clientWg, serverWg)
    }

    private companion object {
        const val GO_ENCAPSULATION_KEY =
            "NAwqy2xgO2TF4/NUIeyX8HtkqmIFgvSobUib6OVUyui894RHBroOGqFUe3cubmeCKOAadEGAvebNqJWgb1azeiG3fCGKlvElZKnPJBqElioMJWvOQBgsl1NpdWsZiEFfEhWEOpeDe0dr73KkILJaZKwqBRgvSjhcb5o3DtUcn2fC3Nh57cygeTwUkUUUVDgGlUpZ9ARG7xFLXGUef8uYdrtiM9XPxOtYwxEt/QVHHuKH+uVT79IcHTwfxcByGOnDUHFn3bYV58FqZAYJ6sFHxXgncQzEtFt+o8cL7tLINdMdA0jA8Ii9M1ZAB2U/+tuIS3sSASSaINbPyOFVfTGyATqrxEubX7x6upN7iPO1LaNc3KpSRCfH5scWAkV6UZh1wtVoqUwwhbJRD0S2aPccdSo84/i4YaGNDoofNUmyyKcw3AF8F4lK7mut7IqEAlsGuFZD2xl/qGaYLUk6qKJQxWKQYFHIQwF0vEcZcpNGetBUGVPKFirBNMIgo0RBpyJmJkGXzieGt9mmkywlInR5YoqLfZKY3NF0iehHhXYbe6qxrPiqwkmgAcxmhvA6cKCtFbZhMZxCgDc4KIexLOFk9QQ9ZaUDa4pv5qiyMXEGOxkYxthszfxHqytIeRRkh9FVsdi13LxQLkgMFwqgNHcXKXwfaWvBvcoBM6QVZdIGnNoEghOdMWkwxKQK4CVEEzoo4plLEXRiBtx/jlghZbLJHfgq/iKRWMZh/1EK4zctFvAH6UYKbbquwHoe9zPJxpLAthmrSTB/IrCVczx2gGDOaQw8QTdrhEbNt6StV1Jioqg6FyEdyYzEi2lEveF/A4IxdbQAPAai8AJe4Sd/2oq4HUyhfIMif8N0U+Nso+oIaYEJZLy8d2o6eKt31HqyuqxVo9qXJ1GeQpUDf+WtXsoNIuaEUrFSGFiVagJz/cGYAkhkcNKlK2a3Z/lV5QUL3JOohLWZFnRSRnZssuRXFceQ9AlemZACiPVzRENyfOQ57aR3RUt/PMoCV0uBTTXFaAwIvmwlPeerV4tDWlNG83E/6/otoTON6PpieptMGEiAgZlTp/lSZUuEKtNdYDFlP2wpi0lIugAtbStwH5wZ6dkR7Sp3M2J9yVByj+JzVKcT1qeOwSO/TJurc5sLUSpIxVCvKGAvtZxpBVZMvalv09ugg6Oz0rBYi0RTL0xCAoQRhEMIfPJIvsJUHvKujfmi1rUlbsuFr4GTUWpVbMzI6MaFuSiPCsuN0mLHzjl6Z4maZgMMKoRJdTdt99xS+HeLziUytZt9zHul/wNVWioXfPawtTeYZGpJdfVKKkk3qOaTvXeWAOBwCvEpKsRjrLlUcwZsO2YRcUefuXluSYUG/Vc0o/HOWiRRwRGgkvm9fRaMG0AcazB7DmPFnqBiKdcfLIY1HjQiXeCwguQpsfBN89KqYihUwqAHcjlN5aVRLeYbYfhqyEyxWcMy1gBuB+J8NBdUx/AUlViBguioYBy1txpQJXNC3gBpQXWK1FVrVCujSupKb0VaR4oeaex3dIOOsrIYPuVTWnoKxDp/DclwPZ7Uq6dsbhIkx8suuYkcAkacJVs="
        const val GO_CIPHERTEXT =
            "jX3iojH0JTQEawt+2KnJ7fAfazFfyhjXBEZ0DBc53AVUl9WWFa/PijsffXZfQKNs0J+bGAenBQ5bdjvvnQ6qEVNQm2qbe11VCeP6SGm2bF01N2tsCwodKIZmts5R2qlRX1oFgomQui8Nqs5EQSteGwBrt/j0W0zYaxRprbUYjoiZtqBCP7vrjh1tLrFc4QsHJBGmREcZqwX+LhoDyf2wt0Udm3JJvwmMAkrVdeRSyT5DMvbdgG0RLZbcHrIJRbevJctUskseMV8nI2BBX92KpoPFWof+ObWuV4fWm8zpMq28nroti7Sbl/wecMEzUADFfYn+dGFXaENYvIdjJuqJZQVWpxwD1qpyg5xs9bKjoEHb7L+ixHwLo3pAamAuHHQEd+rE+5YP292sBwl2o/iEPC8r3r3v5MLvEJow+V/E8czFesW7I6TgBzlOqmqkXqCrA6BBy5/gsStwm+jO139nmNwDze4qYGdpFpqCpy2QNSoEfSRCGlHKW7boum231yv09xpt7KtDRJSsBm6QEVeyHeqRJrwWtHL9n+anHjc0Zopcy92FN9/i/oZvafHx0k6MI1vhtXovUE4oPqwHdBJZRXUy+lsRaaXUiKBeNeXq4Iy+eTcczkZCVm5kMgknYBcTQmw7dFoclPyBO9ENLAZlf5znn2qWH2PHtwOiPt3EY+FyTV2Bb5AZdIJQszBiAzSL88b/ljTuoRPzdWwFCbujvqwQJt44T/zMSlMH/if3mmoik4Z0r7dT0dZonm9VWB5v5N3ih/aCR5TsFSp2E7W3NhGhUETyPZkuK69Ob63dLtTt8N0mtD0qtlTVNXgito1Hrv7AdBDxb06fBVhDibkB/C2ZJvHATpz282PMydxako1mWL55mo+YkrAOtDIxll9l/0lvubQmwahqVu9+nKivxcjfWfq5nI6FtqI/yypdD7lX5n8BjUqsD3T/vleRgaXyXMNbrgKmrEDbte1dkIrRDgjLiU1XZ3keNKHgYoSrp/hgnaIn/9tiatfP/PPEfbo4uDNseW47H82CdoNP8hhBWqXMs9Cn7vZOSk8sVtb0flXsTsXbGFvMFIga6dx0EzAAimF5VZab+FYz/6Rlh/4PKdw8nfSsjlQUYkR4aPY+Zp2Xgw7H8WcYTRbE1zB9UZ6oGfRhr8y705KBC8nWctt5RRzcKhqZI9fa1DuuD4/63LGX/a5CWTdVv4HZuZ31JN8QfexrkxC1SKKJyNHJ1lj18kIJPebNs384E6b+r55lhgAGCOc476D9Yl7YBNumJjq02QC+6QH44umWsQRBOXSwKH3Y5WI6I155YOXyJH4/BldDxMi4wPMS8hf/E/8oqaCo5laGnO9tAfLo/E4EgKXSFBuk943oYECvcCeBO1uDt+/6kRRZxyOuCZ2Dvezu1FpaIYzDuNrSX0rxBaIfP+VppS+N78qexgd+ida3FE5jBWM="
        const val GO_PSK = "ZLYij87SsKipI0jDK0BKZvZTw22f9dSreN4DXUx8nIg="
    }
}
