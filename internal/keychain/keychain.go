// Package keychain keeps secrets in the OS credential store (macOS Keychain, Windows Credential Manager, Secret Service).
package keychain

import (
	"errors"

	"github.com/zalando/go-keyring"
)

// Secret is one item in the credential store.
type Secret struct{ Service, Account string }

// Get returns "" with no error when nothing is stored.
func (s Secret) Get() (string, error) {
	v, err := keyring.Get(s.Service, s.Account)
	if errors.Is(err, keyring.ErrNotFound) {
		return "", nil
	}
	return v, err
}

func (s Secret) Set(v string) error { return keyring.Set(s.Service, s.Account, v) }

func (s Secret) Delete() error {
	if err := keyring.Delete(s.Service, s.Account); err != nil && !errors.Is(err, keyring.ErrNotFound) {
		return err
	}
	return nil
}
