<script lang="ts" setup>
import { ref, computed, onMounted } from "vue"
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
		objectPrefix.value = ""
		tokenStack.value = []
		currentToken.value = undefined
		if (bucket.value.globalAliases.length > 0) {
			fetchObjects()
		}
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

// Object browser
interface ObjectItem {
	key: string
	size: number
	lastModified: string
}
interface ObjectsPage {
	objects: ObjectItem[]
	prefixes: string[]
	nextToken: string | null
	truncated: boolean
}

const objectPrefix = ref("")
const currentToken = ref<string | undefined>(undefined)
const tokenStack = ref<(string | undefined)[]>([])
const objectPage = ref<ObjectsPage | null>(null)
const objectsLoading = ref(false)
const objectsError = ref<Error | null>(null)

const bucketAlias = computed(() => bucket.value?.globalAliases[0] ?? "")
const hasAlias = computed(() => (bucket.value?.globalAliases.length ?? 0) > 0)

const prefixParts = computed(() => {
	if (!objectPrefix.value) return []
	return objectPrefix.value.replace(/\/$/, "").split("/")
})

async function fetchObjects(token?: string) {
	if (!bucketAlias.value) return
	objectsLoading.value = true
	objectsError.value = null
	try {
		const params = new URLSearchParams({ bucket: bucketAlias.value, prefix: objectPrefix.value })
		if (token) params.set("token", token)
		const res = await fetch(`/objects/list?${params}`)
		if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`)
		objectPage.value = await res.json()
	} catch (e) {
		objectsError.value = e as Error
	} finally {
		objectsLoading.value = false
	}
}

function navigateToPrefix(prefix: string) {
	objectPrefix.value = prefix
	currentToken.value = undefined
	tokenStack.value = []
	fetchObjects()
}

function navigateToPart(index: number) {
	const parts = prefixParts.value.slice(0, index + 1)
	navigateToPrefix(parts.join("/") + "/")
}

function nextPage() {
	if (!objectPage.value?.nextToken) return
	tokenStack.value.push(currentToken.value)
	currentToken.value = objectPage.value.nextToken
	fetchObjects(currentToken.value)
}

function prevPage() {
	if (!tokenStack.value.length) return
	currentToken.value = tokenStack.value.pop()
	fetchObjects(currentToken.value)
}

function downloadUrl(key: string): string {
	return `/objects/download?bucket=${encodeURIComponent(bucketAlias.value)}&key=${encodeURIComponent(key)}`
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

			<!-- Object Browser -->
			<div class="flex flex-column gap gap--12">
				<div class="flex flex-wrap justify-between items-center">
					<h2 class="title title-2">Objects</h2>
					<button v-if="hasAlias" class="btn" :class="{ 'btn--loading': objectsLoading }" @click="fetchObjects(currentToken)">
						<PhArrowsCounterClockwise :size="20" weight="bold" />Refresh
					</button>
				</div>

				<div v-if="!hasAlias" class="card color-gray text-small">
					Object browsing requires a global alias.
				</div>

				<template v-else>
					<!-- Breadcrumb -->
					<div v-if="objectPrefix" class="flex flex-wrap items-center gap gap--4 text-small">
						<button class="btn btn--text text-small" @click="navigateToPrefix('')">root</button>
						<template v-for="(part, i) in prefixParts" :key="i">
							<span class="color-gray">/</span>
							<button class="btn btn--text text-small" @click="navigateToPart(i)">{{ part }}</button>
						</template>
					</div>

					<BannerError v-if="objectsError" :error="objectsError" id="objects_error" />

					<div class="card flex flex-column gap" v-if="objectPage">
						<!-- Folders -->
						<button
							v-for="p in objectPage.prefixes"
							:key="p"
							class="btn btn--text"
							style="justify-content: flex-start; text-align: left"
							@click="navigateToPrefix(p)"
						>
							<span class="text-monospace text-small">{{ p.slice(objectPrefix.length) }}</span>
						</button>

						<!-- Objects -->
						<div
							v-for="obj in objectPage.objects"
							:key="obj.key"
							class="flex flex-wrap justify-between items-center gap"
						>
							<span class="text-small text-monospace">{{ obj.key.slice(objectPrefix.length) }}</span>
							<div class="flex flex-wrap gap gap--8 items-center text-small color-gray">
								<span>{{ formatBytes(obj.size).value }}&ThinSpace;<span class="color-gray">{{ formatBytes(obj.size).unit }}</span></span>
								<span>{{ new Date(obj.lastModified).toLocaleDateString() }}</span>
								<a :href="downloadUrl(obj.key)" class="btn" download>Download</a>
							</div>
						</div>

						<div
							v-if="objectPage.objects.length === 0 && objectPage.prefixes.length === 0"
							class="color-gray text-small"
						>
							Empty.
						</div>

						<!-- Pagination -->
						<div class="flex gap" v-if="tokenStack.length > 0 || objectPage.truncated">
							<button class="btn" :disabled="tokenStack.length === 0" @click="prevPage">Previous</button>
							<button class="btn" :disabled="!objectPage.truncated" @click="nextPage">Next</button>
						</div>
					</div>

					<div v-else-if="objectsLoading" class="card color-gray text-small">Loading objects...</div>
				</template>
			</div>
		</div>
	</LayoutDefault>
</template>
