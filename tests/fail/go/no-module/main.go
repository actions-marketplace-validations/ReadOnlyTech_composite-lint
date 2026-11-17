// Package main is a lint fixture, in no module, that should fail.
package main

import "os"

func main() {
	// Expected to fail errcheck: the error returned by os.Remove is ignored
	os.Remove("nothing")
}
