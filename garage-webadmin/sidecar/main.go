package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

var s3Client *s3.Client

func main() {
	cfg, err := config.LoadDefaultConfig(context.Background(),
		config.WithRegion(os.Getenv("region")),
		config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(
			os.Getenv("AWS_ACCESS_KEY_ID"),
			os.Getenv("AWS_SECRET_ACCESS_KEY"),
			"",
		)),
	)
	if err != nil {
		log.Fatalf("failed to load config: %v", err)
	}

	s3Client = s3.NewFromConfig(cfg, func(o *s3.Options) {
		if ep := os.Getenv("endpoint"); ep != "" {
			o.BaseEndpoint = aws.String(ep)
		}
		o.UsePathStyle = true
	})

	mux := http.NewServeMux()
	mux.HandleFunc("/list", handleList)
	mux.HandleFunc("/download", handleDownload)

	log.Println("listening on :8080")
	if err := http.ListenAndServe(":8080", mux); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

type listResponse struct {
	Objects   []objectItem `json:"objects"`
	Prefixes  []string     `json:"prefixes"`
	NextToken *string      `json:"nextToken"`
	Truncated bool         `json:"truncated"`
}

type objectItem struct {
	Key          string    `json:"key"`
	Size         int64     `json:"size"`
	LastModified time.Time `json:"lastModified"`
}

func handleList(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	q := r.URL.Query()
	bucket := q.Get("bucket")
	if bucket == "" {
		http.Error(w, "bucket required", http.StatusBadRequest)
		return
	}
	prefix := q.Get("prefix")
	token := q.Get("token")
	limit := int32(100)
	if l := q.Get("limit"); l != "" {
		if n, err := strconv.Atoi(l); err == nil && n > 0 && n <= 1000 {
			limit = int32(n)
		}
	}

	input := &s3.ListObjectsV2Input{
		Bucket:    aws.String(bucket),
		Delimiter: aws.String("/"),
		MaxKeys:   aws.Int32(limit),
	}
	if prefix != "" {
		input.Prefix = aws.String(prefix)
	}
	if token != "" {
		input.ContinuationToken = aws.String(token)
	}

	out, err := s3Client.ListObjectsV2(r.Context(), input)
	if err != nil {
		http.Error(w, fmt.Sprintf("list error: %v", err), http.StatusInternalServerError)
		return
	}

	resp := listResponse{
		Objects:   make([]objectItem, 0, len(out.Contents)),
		Prefixes:  make([]string, 0, len(out.CommonPrefixes)),
		NextToken: out.NextContinuationToken,
		Truncated: aws.ToBool(out.IsTruncated),
	}
	for _, obj := range out.Contents {
		item := objectItem{Key: aws.ToString(obj.Key), Size: aws.ToInt64(obj.Size)}
		if obj.LastModified != nil {
			item.LastModified = *obj.LastModified
		}
		resp.Objects = append(resp.Objects, item)
	}
	for _, cp := range out.CommonPrefixes {
		resp.Prefixes = append(resp.Prefixes, aws.ToString(cp.Prefix))
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func handleDownload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	q := r.URL.Query()
	bucket := q.Get("bucket")
	key := q.Get("key")
	if bucket == "" || key == "" {
		http.Error(w, "bucket and key required", http.StatusBadRequest)
		return
	}

	out, err := s3Client.GetObject(r.Context(), &s3.GetObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		http.Error(w, fmt.Sprintf("get object error: %v", err), http.StatusInternalServerError)
		return
	}
	defer out.Body.Close()

	if ct := aws.ToString(out.ContentType); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	if out.ContentLength != nil {
		w.Header().Set("Content-Length", strconv.FormatInt(*out.ContentLength, 10))
	}
	filename := key
	if idx := strings.LastIndex(key, "/"); idx >= 0 {
		filename = key[idx+1:]
	}
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename=%q`, filename))

	io.Copy(w, out.Body)
}
