package wg

import (
	"bytes"
	"crypto/hkdf"
	"crypto/mlkem"
	"crypto/rand"
	"crypto/sha256"
	"testing"
)

func randKey(t *testing.T) []byte {
	t.Helper()
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return b
}

// The client side of the exchange: decapsulate and run the same HKDF.
func clientPSK(t *testing.T, dk *mlkem.DecapsulationKey768, ct, clientWG, serverWG []byte) []byte {
	t.Helper()
	ss, err := dk.Decapsulate(ct)
	if err != nil {
		t.Fatalf("decapsulate: %v", err)
	}
	psk, err := hkdf.Key(sha256.New, ss, append(append([]byte{}, clientWG...), serverWG...), mlkem768PSKInfo, 32)
	if err != nil {
		t.Fatal(err)
	}
	return psk
}

func TestMLKEM768RespondRoundTrip(t *testing.T) {
	dk, err := mlkem.GenerateKey768()
	if err != nil {
		t.Fatal(err)
	}
	clientWG, serverWG := randKey(t), randKey(t)

	ct, psk, err := mlkem768Respond(dk.EncapsulationKey().Bytes(), clientWG, serverWG)
	if err != nil {
		t.Fatal(err)
	}
	if len(ct) != mlkem.CiphertextSize768 {
		t.Fatalf("ciphertext is %d bytes, want %d", len(ct), mlkem.CiphertextSize768)
	}
	if len(psk) != 32 {
		t.Fatalf("psk is %d bytes, want 32", len(psk))
	}
	if got := clientPSK(t, dk, ct, clientWG, serverWG); !bytes.Equal(got, psk) {
		t.Fatal("client and server derived different PSKs")
	}

	// A second exchange with the same keys must give a different PSK.
	ct2, psk2, err := mlkem768Respond(dk.EncapsulationKey().Bytes(), clientWG, serverWG)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(ct, ct2) || bytes.Equal(psk, psk2) {
		t.Fatal("two exchanges produced the same ciphertext or PSK")
	}

	// The PSK is bound to the WireGuard key pair.
	if got := clientPSK(t, dk, ct, randKey(t), serverWG); bytes.Equal(got, psk) {
		t.Fatal("PSK did not change with a different client WireGuard key")
	}
}

func TestMLKEM768RespondRejectsBadInput(t *testing.T) {
	dk, err := mlkem.GenerateKey768()
	if err != nil {
		t.Fatal(err)
	}
	ek := dk.EncapsulationKey().Bytes()
	wgA, wgB := randKey(t), randKey(t)

	if _, _, err := mlkem768Respond(ek[:len(ek)-1], wgA, wgB); err == nil {
		t.Fatal("accepted a truncated encapsulation key")
	}
	if _, _, err := mlkem768Respond(wgA, wgA, wgB); err == nil {
		t.Fatal("accepted a 32-byte value as an encapsulation key")
	}
	if _, _, err := mlkem768Respond(ek, wgA[:31], wgB); err == nil {
		t.Fatal("accepted a short WireGuard key")
	}
}
