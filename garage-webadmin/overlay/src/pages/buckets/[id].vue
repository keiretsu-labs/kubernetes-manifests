<script lang="ts" setup>
import { ref, computed, onMounted } from "vue"
import { useRoute, useRouter } from "vue-router"
import LayoutDefault from "../../components/layouts/Default.vue"
import BannerError from "../../components/BannerError.vue"
import Banner from "../../components/Banner.vue"
import { formatBytes, shortId } from "../../utils/labels.ts"
import { client, authenticated } from "../../store.ts"
import { successOrThrow } from "../../utils/api.ts"
import { PhArrowsCounterClockwise, PhArrowLeft, PhTrash, PhUpload, PhFolderPlus } from "@phosphor-icons/vue"

const route = useRoute()
const router = useRouter()

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
const prefixSizes = ref<Record<string, number | null>>({})

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
	prefixSizes.value = {}
	try {
		const params = new URLSearchParams({ bucket: bucketAlias.value, prefix: objectPrefix.value })
		if (token) params.set("token", token)
		const res = await fetch(`/objects/list?${params}`)
		if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`)
		objectPage.value = await res.json()
		for (const p of objectPage.value?.prefixes ?? []) {
			fetchPrefixSize(p)
		}
	} catch (e) {
		objectsError.value = e as Error
	} finally {
		objectsLoading.value = false
	}
}

async function fetchPrefixSize(prefix: string) {
	if (!bucketAlias.value) return
	prefixSizes.value[prefix] = null
	try {
		const params = new URLSearchParams({ bucket: bucketAlias.value, prefix })
		const res = await fetch(`/objects/size?${params}`)
		if (!res.ok) return
		const data = await res.json()
		prefixSizes.value[prefix] = data.size as number
	} catch { /* ignore */ }
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

// Typed confirmation modal
interface DeleteTarget {
	label: string
	confirmText: string
	action: () => Promise<void>
}

const deleteTarget = ref<DeleteTarget | null>(null)
const deleteConfirmInput = ref("")
const deleteLoading = ref(false)
const deleteError = ref<Error | null>(null)
const deleteProgress = ref<number | null>(null)

function confirmDelete(target: DeleteTarget) {
	deleteTarget.value = target
	deleteConfirmInput.value = ""
	deleteError.value = null
	deleteProgress.value = null
}

async function executeDelete() {
	if (!deleteTarget.value || deleteConfirmInput.value !== deleteTarget.value.confirmText) return
	deleteLoading.value = true
	deleteError.value = null
	deleteProgress.value = null
	try {
		await deleteTarget.value.action()
		deleteLoading.value = false
		if (deleteProgress.value !== null) {
			await new Promise<void>((r) => setTimeout(r, 1500))
		}
		deleteTarget.value = null
	} catch (e) {
		deleteError.value = e as Error
		deleteLoading.value = false
	}
}

function cancelDelete() {
	deleteTarget.value = null
	deleteError.value = null
	deleteProgress.value = null
}

async function doSidecarDelete(params: URLSearchParams, onProgress?: (n: number) => void) {
	const res = await fetch(`/objects/delete?${params}`, { method: "DELETE" })
	if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`)
	const ct = res.headers.get("Content-Type") ?? ""
	if (ct.includes("ndjson") && res.body) {
		const reader = res.body.getReader()
		const decoder = new TextDecoder()
		let buf = ""
		while (true) {
			const { done, value } = await reader.read()
			if (done) break
			buf += decoder.decode(value, { stream: true })
			const lines = buf.split("\n")
			buf = lines.pop() ?? ""
			for (const line of lines) {
				if (!line.trim()) continue
				const msg = JSON.parse(line)
				if (msg.error) throw new Error(msg.error)
				if (onProgress) onProgress(msg.deleted as number)
			}
		}
	}
}

function deleteObject(key: string) {
	const name = key.slice(objectPrefix.value.length)
	confirmDelete({
		label: `Permanently delete "${name}"?`,
		confirmText: name,
		action: async () => {
			await doSidecarDelete(new URLSearchParams({ bucket: bucketAlias.value, key }))
			fetchObjects(currentToken.value)
		},
	})
}

function deletePrefix(prefix: string) {
	const name = prefix.slice(objectPrefix.value.length).replace(/\/$/, "")
	confirmDelete({
		label: `Recursively delete folder "${name}" and ALL its contents?`,
		confirmText: name,
		action: async () => {
			await doSidecarDelete(new URLSearchParams({ bucket: bucketAlias.value, prefix }), (n) => {
				deleteProgress.value = n
			})
			fetchObjects(currentToken.value)
		},
	})
}

function deleteBucketFull() {
	if (!bucket.value) return
	const alias = bucket.value.globalAliases[0] ?? ""
	const bucketId = bucket.value.id
	confirmDelete({
		label: `Delete bucket "${alias || shortId(bucketId, "small")}" and ALL its contents? This cannot be undone.`,
		confirmText: alias || bucketId,
		action: async () => {
			if (alias) {
				await doSidecarDelete(new URLSearchParams({ bucket: alias, prefix: "" }), (n) => {
					deleteProgress.value = n
				})
			}
			const res = await fetch(`/api/v2/DeleteBucket?id=${encodeURIComponent(bucketId)}`, {
				method: "POST",
				headers: authenticated.value ? { Authorization: `Bearer ${authenticated.value.token}` } : {},
			})
			if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`)
			router.push("/buckets/")
		},
	})
}

// Upload
const fileInputRef = ref<HTMLInputElement | null>(null)
const uploadLoading = ref(false)
const uploadError = ref<Error | null>(null)

function triggerUpload() {
	fileInputRef.value?.click()
}

async function handleFileSelect(e: Event) {
	const input = e.target as HTMLInputElement
	if (!input.files?.length) return
	const file = input.files[0]!
	const key = objectPrefix.value + file.name

	uploadLoading.value = true
	uploadError.value = null
	try {
		const formData = new FormData()
		formData.append("file", file)
		const params = new URLSearchParams({ bucket: bucketAlias.value, key })
		const res = await fetch(`/objects/upload?${params}`, { method: "POST", body: formData })
		if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`)
		fetchObjects(currentToken.value)
	} catch (e) {
		uploadError.value = e as Error
	} finally {
		uploadLoading.value = false
		input.value = ""
	}
}

// Mkdir
const mkdirVisible = ref(false)
const mkdirName = ref("")
const mkdirLoading = ref(false)
const mkdirError = ref<Error | null>(null)

async function createFolder() {
	if (!mkdirName.value.trim()) return
	const key = objectPrefix.value + mkdirName.value.trim().replace(/\/+$/, "") + "/"
	mkdirLoading.value = true
	mkdirError.value = null
	try {
		const params = new URLSearchParams({ bucket: bucketAlias.value, key })
		const res = await fetch(`/objects/mkdir?${params}`, { method: "POST" })
		if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`)
		mkdirName.value = ""
		mkdirVisible.value = false
		fetchObjects(currentToken.value)
	} catch (e) {
		mkdirError.value = e as Error
	} finally {
		mkdirLoading.value = false
	}
}
</script>

<template>
	<LayoutDefault>
		<!-- Typed confirmation modal -->
		<Teleport to="body">
			<div v-if="deleteTarget" class="modal-backdrop" @click.self="cancelDelete">
				<div class="modal-dialog">
					<p class="modal-label">{{ deleteTarget.label }}</p>
					<p class="text-small color-gray">
						Type <strong class="text-monospace">{{ deleteTarget.confirmText }}</strong> to confirm:
					</p>
					<input
						class="modal-input"
						type="text"
						v-model="deleteConfirmInput"
						:placeholder="deleteTarget.confirmText"
						@keyup.enter="executeDelete"
						autofocus
					/>
					<div v-if="deleteLoading && deleteProgress !== null" class="text-small color-gray">
						Deleting... {{ deleteProgress.toLocaleString() }} objects removed
					</div>
					<BannerError v-if="deleteError" :error="deleteError" id="delete_modal_error" />
					<div class="flex gap gap--8">
						<button class="btn" @click="cancelDelete">Cancel</button>
						<button
							class="btn btn--danger"
							:disabled="deleteConfirmInput !== deleteTarget.confirmText || deleteLoading"
							:class="{ 'btn--loading': deleteLoading }"
							@click="executeDelete"
						>
							<PhTrash :size="16" weight="bold" />Delete
						</button>
					</div>
				</div>
			</div>
		</Teleport>

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
				<button v-if="bucket" class="btn btn--danger" @click="deleteBucketFull">
					<PhTrash :size="20" weight="bold" />Delete Bucket
				</button>
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
					<div v-if="hasAlias" class="flex flex-wrap gap gap--8">
						<button class="btn btn--small" :class="{ 'btn--loading': objectsLoading }" @click="fetchObjects(currentToken)">
							<PhArrowsCounterClockwise :size="16" weight="bold" />Refresh
						</button>
						<button class="btn btn--small" @click="mkdirVisible = !mkdirVisible">
							<PhFolderPlus :size="16" weight="bold" />New Folder
						</button>
						<button class="btn btn--small btn--primary" :class="{ 'btn--loading': uploadLoading }" @click="triggerUpload">
							<PhUpload :size="16" weight="bold" />Upload
						</button>
						<input ref="fileInputRef" type="file" style="display: none" @change="handleFileSelect" />
					</div>
				</div>

				<div v-if="!hasAlias" class="card color-gray text-small">
					Object browsing requires a global alias.
				</div>

				<template v-else>
					<!-- New folder input -->
					<div v-if="mkdirVisible" class="card flex flex-column gap">
						<BannerError v-if="mkdirError" :error="mkdirError" id="mkdir_error" />
						<div class="flex flex-wrap items-center gap gap--8">
							<input
								class="text-small"
								type="text"
								v-model="mkdirName"
								placeholder="folder-name"
								@keyup.enter="createFolder"
								style="flex: 1; min-width: 10rem"
							/>
							<button class="btn btn--small btn--primary" :class="{ 'btn--loading': mkdirLoading }" @click="createFolder">
								Create
							</button>
							<button class="btn btn--small" @click="mkdirVisible = false; mkdirName = ''">
								Cancel
							</button>
						</div>
					</div>

					<!-- Upload error -->
					<BannerError v-if="uploadError" :error="uploadError" id="upload_error" />

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
						<div
							v-for="p in objectPage.prefixes"
							:key="p"
							class="flex flex-wrap justify-between items-center gap"
						>
							<button
								class="btn btn--text"
								style="justify-content: flex-start; text-align: left; flex: 1"
								@click="navigateToPrefix(p)"
							>
								<span class="text-monospace text-small">{{ p.slice(objectPrefix.length) }}</span>
							</button>
							<div class="flex flex-wrap gap gap--8 items-center text-small color-gray">
								<span v-if="p in prefixSizes">
									<template v-if="prefixSizes[p] !== null">
										{{ formatBytes(prefixSizes[p] as number).value }}&ThinSpace;<span class="color-gray">{{ formatBytes(prefixSizes[p] as number).unit }}</span>
									</template>
									<template v-else>…</template>
								</span>
								<button class="btn btn--small btn--danger" @click.stop="deletePrefix(p)" title="Delete folder and all contents">
									<PhTrash :size="14" weight="bold" />
								</button>
							</div>
						</div>

						<!-- Objects -->
						<div
							v-for="obj in objectPage.objects"
							:key="obj.key"
							class="flex flex-wrap justify-between items-center gap"
						>
							<span class="text-small text-monospace" style="flex: 1">{{ obj.key.slice(objectPrefix.length) }}</span>
							<div class="flex flex-wrap gap gap--8 items-center text-small color-gray">
								<span>{{ formatBytes(obj.size).value }}&ThinSpace;<span class="color-gray">{{ formatBytes(obj.size).unit }}</span></span>
								<span>{{ new Date(obj.lastModified).toLocaleDateString() }}</span>
								<a :href="downloadUrl(obj.key)" class="btn btn--small" download>Download</a>
								<button class="btn btn--small btn--danger" @click="deleteObject(obj.key)" title="Delete object">
									<PhTrash :size="14" weight="bold" />
								</button>
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

<style scoped>
.modal-backdrop {
	position: fixed;
	inset: 0;
	background: rgba(0, 0, 0, 0.5);
	display: flex;
	align-items: center;
	justify-content: center;
	z-index: 1000;
}

.modal-dialog {
	background: var(--color-surface, #fff);
	border: 1px solid var(--color-border, #e0e0e0);
	border-radius: 8px;
	padding: 1.5rem;
	max-width: 480px;
	width: 90%;
	display: flex;
	flex-direction: column;
	gap: 0.75rem;
}

.modal-label {
	font-weight: 600;
	margin: 0;
}

.modal-input {
	width: 100%;
	box-sizing: border-box;
}

.btn--danger {
	color: #fff;
	background-color: #c62828;
	border-color: #c62828;
}

.btn--danger:hover:not(:disabled) {
	background-color: #b71c1c;
	border-color: #b71c1c;
}

.btn--danger:disabled {
	opacity: 0.5;
	cursor: not-allowed;
}
</style>
