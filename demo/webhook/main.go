package main

import (
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"strings"
)

type ConversionReview struct {
	APIVersion string              `json:"apiVersion"`
	Kind       string              `json:"kind"`
	Request    *ConversionRequest  `json:"request,omitempty"`
	Response   *ConversionResponse `json:"response,omitempty"`
}

type ConversionRequest struct {
	UID               string                   `json:"uid"`
	DesiredAPIVersion string                   `json:"desiredAPIVersion"`
	Objects           []map[string]interface{} `json:"objects"`
}

type ConversionResponse struct {
	UID              string                   `json:"uid"`
	ConvertedObjects []map[string]interface{} `json:"convertedObjects"`
	Result           Status                   `json:"result"`
}

type Status struct {
	Status string `json:"status"`
}

func versionFrom(apiVersion string) string {
	parts := strings.SplitN(apiVersion, "/", 2)
	if len(parts) == 2 {
		return parts[1]
	}
	return apiVersion
}

func convertObject(obj map[string]interface{}, desiredAPIVersion string) map[string]interface{} {
	src := versionFrom(fmt.Sprint(obj["apiVersion"]))
	dst := versionFrom(desiredAPIVersion)

	spec, _ := obj["spec"].(map[string]interface{})
	if spec == nil {
		spec = map[string]interface{}{}
	}

	if src == "v1alpha1" && (dst == "v1beta1" || dst == "v1") {
		if lp, ok := spec["legacyPort"]; ok {
			spec["portConfig"] = map[string]interface{}{
				"port":     lp,
				"protocol": "TCP",
			}
			delete(spec, "legacyPort")
		}
	}

	if (src == "v1beta1" || src == "v1") && dst == "v1alpha1" {
		if pc, ok := spec["portConfig"].(map[string]interface{}); ok {
			if p, ok := pc["port"]; ok {
				spec["legacyPort"] = p
			}
			delete(spec, "portConfig")
		}
	}

	obj["apiVersion"] = desiredAPIVersion
	obj["spec"] = spec
	return obj
}

func handleConvert(w http.ResponseWriter, r *http.Request) {
	var review ConversionReview
	if err := json.NewDecoder(r.Body).Decode(&review); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	converted := make([]map[string]interface{}, len(review.Request.Objects))
	for i, obj := range review.Request.Objects {
		converted[i] = convertObject(obj, review.Request.DesiredAPIVersion)
	}

	review.Response = &ConversionResponse{
		UID:              review.Request.UID,
		ConvertedObjects: converted,
		Result:           Status{Status: "Success"},
	}
	review.Request = nil

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(review)
}

func main() {
	certFile := flag.String("tls-cert", "/tls/tls.crt", "TLS certificate file")
	keyFile := flag.String("tls-key", "/tls/tls.key", "TLS key file")
	port := flag.Int("port", 8443, "HTTPS port")
	flag.Parse()

	mux := http.NewServeMux()
	mux.HandleFunc("/convert", handleConvert)

	server := &http.Server{
		Addr:      fmt.Sprintf(":%d", *port),
		Handler:   mux,
		TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12},
	}
	log.Printf("Starting conversion webhook on :%d", *port)
	log.Fatal(server.ListenAndServeTLS(*certFile, *keyFile))
}
