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
	"github.com/aws/aws-sdk-go-v2/feature/s3/manager"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

var (
	s3Client *s3.Client
	uploader *manager.Uploader
)

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

	uploader = manager.NewUploader(s3Client)

	mux := http.NewServeMux()
	mux.HandleFunc("/list", handleList)
	mux.HandleFunc("/download", handleDownload)
	mux.HandleFunc("/delete", handleDelete)
	mux.HandleFunc("/upload", handleUpload)
	mux.HandleFunc("/mkdir", handleMkdir)
	mux.HandleFunc("/size", handleSize)

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

func handleDelete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	q := r.URL.Query()
	bucket := q.Get("bucket")
	if bucket == "" {
		http.Error(w, "bucket required", http.StatusBadRequest)
		return
	}

	_, hasKey := q["key"]
	_, hasPrefix := q["prefix"]

	switch {
	case hasKey:
		key := q.Get("key")
		if _, err := s3Client.DeleteObject(r.Context(), &s3.DeleteObjectInput{
			Bucket: aws.String(bucket),
			Key:    aws.String(key),
		}); err != nil {
			http.Error(w, fmt.Sprintf("delete error: %v", err), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]int{"deleted": 1})

	case hasPrefix:
		prefix := q.Get("prefix")
		w.Header().Set("Content-Type", "application/x-ndjson")
		w.Header().Set("X-Accel-Buffering", "no")
		w.Header().Set("Cache-Control", "no-cache")
		flusher, _ := w.(http.Flusher)
		deleted, err := deleteByPrefix(r.Context(), bucket, prefix, func(n int) {
			json.NewEncoder(w).Encode(map[string]any{"deleted": n, "done": false})
			if flusher != nil {
				flusher.Flush()
			}
		})
		if err != nil {
			json.NewEncoder(w).Encode(map[string]any{"error": err.Error(), "deleted": deleted, "done": true})
		} else {
			json.NewEncoder(w).Encode(map[string]any{"deleted": deleted, "done": true})
		}
		if flusher != nil {
			flusher.Flush()
		}

	default:
		http.Error(w, "key or prefix parameter required", http.StatusBadRequest)
	}
}

func deleteByPrefix(ctx context.Context, bucket, prefix string, progress func(int)) (int, error) {
	var deleted int
	var token *string
	for {
		input := &s3.ListObjectsV2Input{
			Bucket:            aws.String(bucket),
			MaxKeys:           aws.Int32(1000),
			ContinuationToken: token,
		}
		if prefix != "" {
			input.Prefix = aws.String(prefix)
		}
		out, err := s3Client.ListObjectsV2(ctx, input)
		if err != nil {
			return deleted, err
		}
		if len(out.Contents) == 0 {
			break
		}
		objs := make([]types.ObjectIdentifier, len(out.Contents))
		for i, obj := range out.Contents {
			objs[i] = types.ObjectIdentifier{Key: obj.Key}
		}
		if _, err := s3Client.DeleteObjects(ctx, &s3.DeleteObjectsInput{
			Bucket: aws.String(bucket),
			Delete: &types.Delete{Objects: objs, Quiet: aws.Bool(true)},
		}); err != nil {
			return deleted, err
		}
		deleted += len(objs)
		if progress != nil {
			progress(deleted)
		}
		if !aws.ToBool(out.IsTruncated) {
			break
		}
		token = out.NextContinuationToken
	}
	return deleted, nil
}

func handleSize(w http.ResponseWriter, r *http.Request) {
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

	var totalSize int64
	var count int64
	var token *string
	for {
		input := &s3.ListObjectsV2Input{
			Bucket:            aws.String(bucket),
			MaxKeys:           aws.Int32(1000),
			ContinuationToken: token,
		}
		if prefix != "" {
			input.Prefix = aws.String(prefix)
		}
		out, err := s3Client.ListObjectsV2(r.Context(), input)
		if err != nil {
			http.Error(w, fmt.Sprintf("size error: %v", err), http.StatusInternalServerError)
			return
		}
		for _, obj := range out.Contents {
			totalSize += aws.ToInt64(obj.Size)
			count++
		}
		if !aws.ToBool(out.IsTruncated) {
			break
		}
		token = out.NextContinuationToken
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]int64{"size": totalSize, "count": count})
}

func handleUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
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

	if err := r.ParseMultipartForm(32 << 20); err != nil {
		http.Error(w, fmt.Sprintf("parse error: %v", err), http.StatusBadRequest)
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		http.Error(w, fmt.Sprintf("file error: %v", err), http.StatusBadRequest)
		return
	}
	defer file.Close()

	ct := header.Header.Get("Content-Type")
	if ct == "" {
		ct = "application/octet-stream"
	}

	if _, err := uploader.Upload(r.Context(), &s3.PutObjectInput{
		Bucket:      aws.String(bucket),
		Key:         aws.String(key),
		Body:        file,
		ContentType: aws.String(ct),
	}); err != nil {
		http.Error(w, fmt.Sprintf("upload error: %v", err), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"key": key})
}

func handleMkdir(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
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
	if !strings.HasSuffix(key, "/") {
		key += "/"
	}

	if _, err := s3Client.PutObject(r.Context(), &s3.PutObjectInput{
		Bucket:        aws.String(bucket),
		Key:           aws.String(key),
		Body:          strings.NewReader(""),
		ContentLength: aws.Int64(0),
	}); err != nil {
		http.Error(w, fmt.Sprintf("mkdir error: %v", err), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"key": key})
}
