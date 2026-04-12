import { fetchAuthenticated } from "./utils/create-api-client.ts"
import { authenticated } from "./store.ts"

const token = (window as any).__GARAGE_TOKEN as string | undefined
if (token && authenticated.value === null) {
	try {
		authenticated.value = await fetchAuthenticated(token)
	} catch (e) {
		console.warn("auto-login failed:", e)
	}
}
