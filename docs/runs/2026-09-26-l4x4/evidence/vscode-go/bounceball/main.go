package main

import (
	"log"
	"mime"
	"net/http"
	"os"
	"path/filepath"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8000"
	}

	http.HandleFunc("/", homeHandler)
	http.HandleFunc("/assets/", assetsHandler)

	addr := ":" + port
	log.Printf("Bounce Ball is running at http://localhost:%s", port)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatal(err)
	}
}

func homeHandler(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	b, err := os.ReadFile("static/index.html")
	if err != nil {
		http.Error(w, "could not load page: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(b)
}

func assetsHandler(w http.ResponseWriter, r *http.Request) {
	name := filepath.Base(r.URL.Path)
	b, err := os.ReadFile("static/" + name)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", mime.TypeByExtension(filepath.Ext(name)))
	w.Write(b)
}
