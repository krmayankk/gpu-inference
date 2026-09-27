package main

import (
	"fmt"
)

func binarySearch(arr []int, target int) int {
	left, right := 0, len(arr)-1
	for left <= right {
		mid := left + (right-left)/2
		if arr[mid] == target {
			return mid
		} else if arr[mid] < target {
			left = mid + 1
		} else {
			right = mid - 1
		}
	}
	return -1
}

func main() {
	arr := []int{2, 5, 8, 12, 16, 23, 38, 56, 72, 91}
	targets := []int{23, 5, 100, 56, 2}
	for _, t := range targets {
		idx := binarySearch(arr, t)
		if idx != -1 {
			fmt.Printf("Target %d found at index %d\n", t, idx)
		} else {
			fmt.Printf("Target %d not found\n", t)
		}
	}
}
