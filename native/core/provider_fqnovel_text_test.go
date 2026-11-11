package core

import (
	"bytes"
	"compress/gzip"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"testing"
)

func TestParseAudiobookTextReadsTimedSpans(t *testing.T) {
	document := `<header></header><article><p idx="0">{!-- PGC_VOICE:{&#34;duration&#34;:&#34;896&#34;} --}</p><p></p>` +
		`<div class="novel-fm-asr"><p idx="1"><span start_time="1370">擂台之上，</span><span start_time="2390">叶枫&amp;冷笑。</span></p>` +
		`<p idx="2"><span start_time="6170">人群中响起辱骂声。</span></p></div><p>普通段落</p></article>`
	got := parseAudiobookText(document)
	if len(got) != 3 || got[0].Text != "擂台之上，叶枫&冷笑。" || got[0].Start != 1.37 || len(got[0].Segments) != 2 ||
		got[0].Segments[1].Start != 2.39 || got[1].Start != 6.17 || got[2].Text != "普通段落" || got[2].Start != -1 {
		t.Fatalf("%+v", got)
	}
}

func TestFqnovelDecryptRoundTrip(t *testing.T) {
	key := []byte("0123456789abcdef")
	var zipped bytes.Buffer
	writer := gzip.NewWriter(&zipped)
	writer.Write([]byte("<p>正文</p>"))
	writer.Close()
	iv := bytes.Repeat([]byte{7}, aes.BlockSize)
	block, _ := aes.NewCipher(key)
	padded := pkcs7Pad(zipped.Bytes(), aes.BlockSize)
	encrypted := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(encrypted, padded)
	plain, err := fqnovelDecrypt(key, base64.StdEncoding.EncodeToString(append(iv, encrypted...)))
	if err != nil || !bytes.Equal(plain, zipped.Bytes()) {
		t.Fatal(err)
	}
	content, err := fqnovelRegisterContent("2204995525808432")
	if err != nil {
		t.Fatal(err)
	}
	raw, err := fqnovelDecrypt(fqnovelRegisterKey, content)
	if err != nil || len(raw) != 16 || raw[0] == 0 {
		t.Fatal("register content", err, raw)
	}
}
