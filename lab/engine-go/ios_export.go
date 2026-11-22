//go:build ios && cgo

package main

import "C"

//export YingzhouGoStart
func YingzhouGoStart(port C.int, directory *C.char, failure **C.char) C.int {
	actual, err := StartMobileEngine(int(port), C.GoString(directory))
	if err != nil {
		if failure != nil {
			*failure = C.CString(err.Error())
		}
		return 0
	}
	return C.int(actual)
}

//export YingzhouGoStop
func YingzhouGoStop() {
	StopMobileEngine()
}
