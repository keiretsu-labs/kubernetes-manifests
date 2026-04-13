<script lang="ts" setup>
import { ref, onMounted } from "vue"
import { useRoute } from "vue-router"
import LayoutDefault from "../../components/layouts/Default.vue"
import BannerError from "../../components/BannerError.vue"
import Banner from "../../components/Banner.vue"
import { formatBytes, shortId } from "../../utils/labels.ts"
import { client } from "../../store.ts"
import { successOrThrow } from "../../utils/api.ts"
import { PhArrowsCounterClockwise, PhArrowLeft } from "@phosphor-icons/vue"

const route = useRoute()

async function fetchBucketData() {
	return await successOrThrow(
		await client.GET("/v2/GetBucketInfo", { params: { query: { id: route.params.id as string } } }),
	)
}

const bucket = ref<Awaited<ReturnType<typeof fetchBucketData>> | null>(null)
const isLoading = ref(false)
const error = ref<Error | null>(null)

async function fetchBucket() {
	isLoading.value = true
	error.value = null
	try {
		bucket.value = await fetchBucketData()
	} catch (e) {
		error.value = e as Error
	} finally {
		isLoading.value = false
	}
}

onMounted(fetchBucket)

const cleanupHours = ref(24)
const cleanupLoading = ref(false)
const cleanupResult = ref<number | null>(null)
const cleanupError = ref<Error | null>(null)

async function runCleanup() {
	if (!bucket.value) return
	cleanupLoading.value = true
	cleanupResult.value = null
	cleanupError.value = null
	try {
		const res = await client.POST("/v2/CleanupIncompleteUploads", {
			body: { bucketId: bucket.value.id, olderThanSecs: cleanupHours.value * 3600 },
		})
		if (res.error) throw new Error(String(res.error))
		cleanupResult.value = res.data?.uploadsDeleted ?? 0
		fetchBucket()
	} catch (e) {
		cleanupError.value = e as Error
	} finally {
		cleanupLoading.value = false
	}
}
</script>

<template>
	<LayoutDefault>
		<div class="sectionHeader">
			<div class="sectionHeader-content">
				<router-link to="/buckets/" class="btn btn--text">
					<PhArrowLeft :size="20" weight="bold" />Buckets
				</router-link>
				<h1 class="title title-1" v-if="bucket">
					{{ bucket.globalAliases.length > 0 ? bucket.globalAliases.join(", ") : shortId(bucket.id, "small") }}
				</h1>
			</div>
			<div class="sectionHeader-side">
				<button class="btn" :class="{ 'btn--loading': isLoading }" @click="fetchBucket">
					<PhArrowsCounterClockwise :size="20" weight="bold" />Refresh
				</button>
			</div>
		</div>

		<BannerError v-if="error" :error="error" id="api_error_bucket_info" />

		<div class="flex flex-column gap gap--12" v-if="bucket">
			<!-- Summary -->
			<dl class="summary">
				<div class="summary-cell">
					<dt class="summary-label">Objects</dt>
					<dd class="summary-detail">{{ bucket.objects.toLocaleString() }}</dd>
				</div>
				<div class="summary-cell">
					<dt class="summary-label">Size</dt>
					<dd class="summary-detail">
						{{ formatBytes(bucket.bytes).value }}&ThinSpace;
						<span class="color-gray text-normal">{{ formatBytes(bucket.bytes).unit }}</span>
					</dd>
				</div>
				<div class="summary-cell" v-if="bucket.quotas.maxSize">
					<dt class="summary-label">Size quota</dt>
					<dd class="summary-detail">
						{{ formatBytes(bucket.quotas.maxSize).value }}&ThinSpace;
						<span class="color-gray text-normal">{{ formatBytes(bucket.quotas.maxSize).unit }}</span>
					</dd>
				</div>
				<div class="summary-cell" v-if="bucket.quotas.maxObjects">
					<dt class="summary-label">Object quota</dt>
					<dd class="summary-detail">{{ bucket.quotas.maxObjects.toLocaleString() }}</dd>
				</div>
				<div class="summary-cell">
					<dt class="summary-label">Website</dt>
					<dd class="summary-detail">{{ bucket.websiteAccess ? "Enabled" : "Disabled" }}</dd>
				</div>
				<div class="summary-cell">
					<dt class="summary-label">Created</dt>
					<dd class="summary-detail text-normal">{{ new Date(bucket.created).toLocaleDateString() }}</dd>
				</div>
			</dl>

			<!-- Bucket ID -->
			<div class="card flex flex-wrap items-center gap gap--8">
				<span class="color-gray text-small">Bucket ID</span>
				<span class="text-monospace text-small">{{ bucket.id }}</span>
			</div>

			<!-- Access Keys -->
			<div class="flex flex-column gap gap--12">
				<h2 class="title title-2">Access Keys</h2>
				<div v-if="bucket.keys.length === 0" class="card color-gray text-small">No access keys have permissions on this bucket.</div>
				<template v-else>
					<div v-for="key in bucket.keys" :key="key.accessKeyId" class="card flex flex-wrap justify-between items-center gap">
						<div class="flex flex-column gap">
							<div class="text-semibold text-monospace">{{ key.accessKeyId }}</div>
							<div class="color-gray text-small" v-if="key.name">{{ key.name }}</div>
							<div class="text-small color-gray" v-if="key.bucketLocalAliases.length > 0">
								Local aliases: {{ key.bucketLocalAliases.join(", ") }}
							</div>
						</div>
						<div class="flex flex-wrap gap gap--8 items-center text-small">
							<span v-if="key.permissions.owner" class="tag tag--small tag--orange">owner</span>
							<span v-if="key.permissions.read" class="tag tag--small tag--green">read</span>
							<span v-if="key.permissions.write" class="tag tag--small tag--green">write</span>
							<span v-if="!key.permissions.read && !key.permissions.write && !key.permissions.owner" class="tag tag--small">no permissions</span>
						</div>
					</div>
				</template>
			</div>

			<!-- Incomplete Uploads -->
			<div class="flex flex-column gap gap--12" v-if="bucket.unfinishedUploads > 0 || bucket.unfinishedMultipartUploads > 0">
				<h2 class="title title-2">Incomplete Uploads</h2>
				<div class="card flex flex-column gap">
					<dl class="summary">
						<div class="summary-cell">
							<dt class="summary-label">Unfinished uploads</dt>
							<dd class="summary-detail">{{ bucket.unfinishedUploads }}</dd>
						</div>
						<div class="summary-cell">
							<dt class="summary-label">Unfinished multipart</dt>
							<dd class="summary-detail">{{ bucket.unfinishedMultipartUploads }}</dd>
						</div>
						<div class="summary-cell">
							<dt class="summary-label">Multipart parts</dt>
							<dd class="summary-detail">{{ bucket.unfinishedMultipartUploadParts }}</dd>
						</div>
						<div class="summary-cell">
							<dt class="summary-label">Multipart bytes</dt>
							<dd class="summary-detail">
								{{ formatBytes(bucket.unfinishedMultipartUploadBytes).value }}&ThinSpace;
								<span class="color-gray text-normal">{{ formatBytes(bucket.unfinishedMultipartUploadBytes).unit }}</span>
							</dd>
						</div>
					</dl>
					<Banner v-if="cleanupResult !== null" type="info" icon>
						Deleted {{ cleanupResult }} incomplete upload{{ cleanupResult === 1 ? "" : "s" }}.
					</Banner>
					<BannerError v-if="cleanupError" :error="cleanupError" id="cleanup_error" />
					<div class="flex flex-wrap items-center gap">
						<label class="color-gray text-small">Older than</label>
						<input class="text-small" type="number" min="1" v-model="cleanupHours" style="width: 5rem" />
						<span class="color-gray text-small">hours</span>
						<button class="btn btn--primary" :class="{ 'btn--loading': cleanupLoading }" @click="runCleanup">
							Clean up
						</button>
					</div>
				</div>
			</div>

			<!-- Website Config -->
			<div class="flex flex-column gap gap--12" v-if="bucket.websiteAccess && bucket.websiteConfig">
				<h2 class="title title-2">Website Configuration</h2>
				<div class="card flex flex-column gap">
					<div>Index document: <span class="text-semibold text-monospace">{{ bucket.websiteConfig.indexDocument }}</span></div>
					<div v-if="bucket.websiteConfig.errorDocument">
						Error document: <span class="text-semibold text-monospace">{{ bucket.websiteConfig.errorDocument }}</span>
					</div>
				</div>
			</div>
		</div>
	</LayoutDefault>
</template>
