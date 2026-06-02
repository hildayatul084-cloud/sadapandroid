// ============================================
// W8PREMIUMYT SMS GATEWAY BACKEND SERVER
// ============================================

require('dotenv').config()
const express = require('express')
const cors = require('cors')
const bodyParser = require('body-parser')
const http = require('http')
const { Server } = require('socket.io')
const { Pool } = require('pg')

const app = express()
const server = http.createServer(app)
const io = new Server(server, {
	cors: {
		origin: process.env.FRONTEND_URL || '*',
		methods: ['GET', 'POST']
	}
})

// ============================================
// MIDDLEWARE
// ============================================
app.use(
	cors({
		origin: process.env.FRONTEND_URL || '*',
		credentials: true
	})
)
app.use(bodyParser.json())
app.use(bodyParser.urlencoded({ extended: true }))

// ============================================
// DATABASE CONNECTION (PostgreSQL Supabase)
// ============================================
const pool = new Pool({
	connectionString: process.env.DATABASE_URL,
	ssl: {
		rejectUnauthorized: false
	}
})

// Test koneksi database
pool.connect((err, client, release) => {
	if (err) {
		console.error('❌ Database connection error:', err.stack)
	} else {
		console.log('✅ Connected to PostgreSQL Supabase')
		release()
	}
})

// ============================================
// AUTHENTICATION MIDDLEWARE
// ============================================
const validateApiKey = (req, res, next) => {
	const apiKey = req.headers['x-api-key'] || req.query.api_key

	if (!apiKey) {
		return res.status(401).json({
			success: false,
			message: 'API Key diperlukan'
		})
	}

	if (apiKey !== process.env.API_KEY) {
		return res.status(403).json({
			success: false,
			message: 'API Key tidak valid'
		})
	}

	next()
}

// ============================================
// WEBSOCKET CONNECTION HANDLER
// ============================================
let connectedClients = 0

io.on('connection', socket => {
	connectedClients++
	console.log(`🔌 Client connected. Total: ${connectedClients}`)

	// Kirim status koneksi
	socket.emit('connection_status', {
		connected: true,
		timestamp: new Date().toISOString()
	})

	socket.on('disconnect', () => {
		connectedClients--
		console.log(`🔌 Client disconnected. Total: ${connectedClients}`)
	})
})

// ============================================
// ROUTE: ROOT
// ============================================
app.get('/', (req, res) => {
	res.json({
		success: true,
		service: 'W8PREMIUMYT SMS Gateway Backend',
		version: '1.0.0',
		status: 'running',
		timestamp: new Date().toISOString()
	})
})

// ============================================
// ROUTE: HEALTH CHECK
// ============================================
app.get('/health', async (req, res) => {
	try {
		// Test database connection
		await pool.query('SELECT NOW()')

		res.json({
			success: true,
			status: 'healthy',
			database: 'connected',
			websocket_clients: connectedClients,
			timestamp: new Date().toISOString()
		})
	} catch (error) {
		res.status(500).json({
			success: false,
			status: 'unhealthy',
			database: 'disconnected',
			error: error.message
		})
	}
})

// ============================================
// ROUTE: TERIMA SMS DARI APK
// ============================================
app.post('/api/sms-masuk', validateApiKey, async (req, res) => {
	try {
		const { sender, message, timestamp, device_id, device_name } = req.body

		// Validasi input
		if (!sender || !message) {
			return res.status(400).json({
				success: false,
				message: 'Data sender dan message wajib diisi'
			})
		}

		// Simpan ke database
		const query = `
      INSERT INTO sms_inbox 
      (sender, message, timestamp, device_id, device_name, received_at)
      VALUES ($1, $2, $3, $4, $5, NOW())
      RETURNING *
    `

		const values = [sender, message, timestamp || new Date().toISOString(), device_id || 'unknown', device_name || 'Unknown Device']

		const result = await pool.query(query, values)
		const savedSms = result.rows[0]

		console.log('📨 SMS masuk dari:', sender)

		// Broadcast ke semua dashboard via WebSocket
		io.emit('new_sms', {
			id: savedSms.id,
			sender: savedSms.sender,
			message: savedSms.message,
			timestamp: savedSms.timestamp,
			device_id: savedSms.device_id,
			device_name: savedSms.device_name,
			received_at: savedSms.received_at
		})

		res.status(201).json({
			success: true,
			message: 'SMS berhasil diterima',
			data: savedSms
		})
	} catch (error) {
		console.error('❌ Error menyimpan SMS:', error)
		res.status(500).json({
			success: false,
			message: 'Gagal menyimpan SMS',
			error: error.message
		})
	}
})

// ============================================
// ROUTE: HEARTBEAT / PING DEVICE
// ============================================
app.post('/api/heartbeat', validateApiKey, async (req, res) => {
	try {
		const { device_id, device_name, battery_level } = req.body

		if (!device_id) {
			return res.status(400).json({
				success: false,
				message: 'device_id wajib diisi'
			})
		}

		// Update atau insert status device
		const query = `
      INSERT INTO device_status 
      (device_id, device_name, battery_level, last_ping, status)
      VALUES ($1, $2, $3, NOW(), 'online')
      ON CONFLICT (device_id) 
      DO UPDATE SET 
        device_name = EXCLUDED.device_name,
        battery_level = EXCLUDED.battery_level,
        last_ping = NOW(),
        status = 'online'
      RETURNING *
    `

		const values = [device_id, device_name || 'Unknown Device', battery_level || 0]

		const result = await pool.query(query, values)
		const deviceStatus = result.rows[0]

		// Broadcast status device ke dashboard
		io.emit('device_status', {
			device_id: deviceStatus.device_id,
			device_name: deviceStatus.device_name,
			battery_level: deviceStatus.battery_level,
			status: deviceStatus.status,
			last_ping: deviceStatus.last_ping
		})

		res.json({
			success: true,
			message: 'Heartbeat diterima',
			data: deviceStatus
		})
	} catch (error) {
		console.error('❌ Error heartbeat:', error)
		res.status(500).json({
			success: false,
			message: 'Gagal memproses heartbeat',
			error: error.message
		})
	}
})

// ============================================
// ROUTE: GET ALL SMS (untuk dashboard)
// ============================================
app.get('/api/sms', validateApiKey, async (req, res) => {
	try {
		const limit = parseInt(req.query.limit) || 100
		const offset = parseInt(req.query.offset) || 0

		const query = `
      SELECT * FROM sms_inbox 
      ORDER BY received_at DESC 
      LIMIT $1 OFFSET $2
    `

		const result = await pool.query(query, [limit, offset])

		// Get total count
		const countResult = await pool.query('SELECT COUNT(*) FROM sms_inbox')
		const total = parseInt(countResult.rows[0].count)

		res.json({
			success: true,
			data: result.rows,
			pagination: {
				total,
				limit,
				offset,
				page: Math.floor(offset / limit) + 1,
				total_pages: Math.ceil(total / limit)
			}
		})
	} catch (error) {
		console.error('❌ Error get SMS:', error)
		res.status(500).json({
			success: false,
			message: 'Gagal mengambil data SMS',
			error: error.message
		})
	}
})

// ============================================
// ROUTE: GET DEVICE STATUS
// ============================================
app.get('/api/devices', validateApiKey, async (req, res) => {
	try {
		const query = `
      SELECT 
        *,
        CASE 
          WHEN last_ping > NOW() - INTERVAL '15 minutes' THEN 'online'
          ELSE 'offline'
        END as current_status
      FROM device_status
      ORDER BY last_ping DESC
    `

		const result = await pool.query(query)

		res.json({
			success: true,
			data: result.rows
		})
	} catch (error) {
		console.error('❌ Error get devices:', error)
		res.status(500).json({
			success: false,
			message: 'Gagal mengambil data device',
			error: error.message
		})
	}
})

// ============================================
// ROUTE: DELETE SMS (opsional)
// ============================================
app.delete('/api/sms/:id', validateApiKey, async (req, res) => {
	try {
		const { id } = req.params

		const query = 'DELETE FROM sms_inbox WHERE id = $1 RETURNING *'
		const result = await pool.query(query, [id])

		if (result.rows.length === 0) {
			return res.status(404).json({
				success: false,
				message: 'SMS tidak ditemukan'
			})
		}

		res.json({
			success: true,
			message: 'SMS berhasil dihapus',
			data: result.rows[0]
		})
	} catch (error) {
		console.error('❌ Error delete SMS:', error)
		res.status(500).json({
			success: false,
			message: 'Gagal menghapus SMS',
			error: error.message
		})
	}
})

// ============================================
// ROUTE: STATISTIK
// ============================================
app.get('/api/stats', validateApiKey, async (req, res) => {
	try {
		// Total SMS
		const totalSmsResult = await pool.query('SELECT COUNT(*) FROM sms_inbox')
		const totalSms = parseInt(totalSmsResult.rows[0].count)

		// SMS hari ini
		const todaySmsResult = await pool.query(`
      SELECT COUNT(*) FROM sms_inbox 
      WHERE received_at::date = CURRENT_DATE
    `)
		const todaySms = parseInt(todaySmsResult.rows[0].count)

		// Device online
		const onlineDevicesResult = await pool.query(`
      SELECT COUNT(*) FROM device_status 
      WHERE last_ping > NOW() - INTERVAL '15 minutes'
    `)
		const onlineDevices = parseInt(onlineDevicesResult.rows[0].count)

		// Total devices
		const totalDevicesResult = await pool.query('SELECT COUNT(*) FROM device_status')
		const totalDevices = parseInt(totalDevicesResult.rows[0].count)

		res.json({
			success: true,
			data: {
				total_sms: totalSms,
				today_sms: todaySms,
				online_devices: onlineDevices,
				total_devices: totalDevices,
				websocket_clients: connectedClients
			}
		})
	} catch (error) {
		console.error('❌ Error get stats:', error)
		res.status(500).json({
			success: false,
			message: 'Gagal mengambil statistik',
			error: error.message
		})
	}
})

// ============================================
// ERROR HANDLER
// ============================================
app.use((err, req, res, next) => {
	console.error('❌ Unhandled error:', err)
	res.status(500).json({
		success: false,
		message: 'Internal server error',
		error: err.message
	})
})

// ============================================
// START SERVER
// ============================================
const PORT = process.env.PORT || 3000

server.listen(PORT, () => {
	console.log('===========================================')
	console.log('🚀 W8PREMIUMYT SMS Gateway Backend')
	console.log('===========================================')
	console.log(`✅ Server running on port ${PORT}`)
	console.log(`🌐 Environment: ${process.env.NODE_ENV || 'development'}`)
	console.log(`🔌 WebSocket enabled`)
	console.log('===========================================')
})

// Graceful shutdown
process.on('SIGTERM', () => {
	console.log('🛑 SIGTERM signal received: closing HTTP server')
	server.close(() => {
		console.log('✅ HTTP server closed')
		pool.end(() => {
			console.log('✅ Database pool closed')
			process.exit(0)
		})
	})
})
