package core

import "crypto/md5"

// XChinaEVPKey 按 OpenSSL EVP_BytesToKey（MD5）由口令与盐派生 key/iv。
// XChina 与 Theporny 共用同一套派生逻辑，所以放在运行时而不是某个站源里。
func XChinaEVPKey(password, salt []byte) ([]byte, []byte) {
	derived := make([]byte, 0, 48)
	var previous []byte
	for len(derived) < 48 {
		sum := md5.Sum(append(append(append([]byte(nil), previous...), password...), salt...))
		previous = sum[:]
		derived = append(derived, previous...)
	}
	return derived[:32], derived[32:48]
}

// xchinaEVPKey 保留内部短名，站源外置后 Theporny 仍在本包里调用。
func xchinaEVPKey(password, salt []byte) ([]byte, []byte) {
	return XChinaEVPKey(password, salt)
}
