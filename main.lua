require "import"
import "android.widget.*"
import "android.view.*"
import "android.content.Intent"
import "android.content.Context"
import "android.net.Uri"
import "android.app.AlertDialog"
import "android.os.Handler"
import "android.os.Looper"
import "android.location.LocationManager"
import "android.location.Location"
import "android.location.LocationListener"
import "android.speech.tts.TextToSpeech"
import "java.util.Locale"
import "java.net.URL"
import "java.net.HttpURLConnection"
import "java.io.BufferedReader"
import "java.io.InputStreamReader"
import "java.lang.Thread"
import "java.lang.Runnable"

local json = require "cjson"

local PREF_NAME = "jieshuo_maps_config"
local KEY_API = "locationiq_access_token"
local KEY_BOOKMARKS = "saved_locations_json"
local KEY_TTS_ENGINE = "selected_tts_engine"
local KEY_NAV_ACTIVE = "nav_is_active"
local KEY_LAST_TARGET = "last_target_json"
local KEY_START_LOC = "start_loc_json"

local context = service
local mainHandler = Handler(Looper.getMainLooper())

local activeLocationListener = nil
local activeTargetItem = nil
local activeStartLoc = nil
local ttsEngine = nil
local isTtsReady = false

function runOnUI(func)
  mainHandler.post(Runnable({
    run = function()
      pcall(func)
    end
  }))
end

-- ========================================================
-- FUNGSI TAMPILAN KOSONG (AMAN DARI BLOKIR MIUI 14)
-- ========================================================
function tampilkanFloatingNavigasi(teksAwal) end
function updateFloatingNavigasi(teksBaru) end
function tutupFloatingNavigasi() end

-- ========================================================
-- KONTROL STATUS NAVIGASI & TITIK AWAL PERJALANAN
-- ========================================================
function setNavigasiAktifStatus(status, targetItem, startLoc)
  pcall(function()
    local sp = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
    local editor = sp.edit()
    editor.putBoolean(KEY_NAV_ACTIVE, status)
    if targetItem and startLoc then
      editor.putString(KEY_LAST_TARGET, json.encode(targetItem))
      editor.putString(KEY_START_LOC, json.encode(startLoc))
    else
      editor.remove(KEY_LAST_TARGET)
      editor.remove(KEY_START_LOC)
    end
    editor.apply()
  end)
end

function getActiveTargetItem()
  if activeTargetItem ~= nil then
    return activeTargetItem
  end
  local target = nil
  pcall(function()
    local sp = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
    local rawJson = sp.getString(KEY_LAST_TARGET, "")
    if rawJson ~= "" then
      target = json.decode(rawJson)
    end
  end)
  return target
end

function getActiveStartLoc()
  if activeStartLoc ~= nil then
    return activeStartLoc
  end
  local startLoc = nil
  pcall(function()
    local sp = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
    local rawJson = sp.getString(KEY_START_LOC, "")
    if rawJson ~= "" then
      startLoc = json.decode(rawJson)
    end
  end)
  return startLoc
end

-- ========================================================
-- KONTROL TTS NAVIGASI & PENGHENTIAN
-- ========================================================
function getSavedTtsEngine()
  local sp = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
  return sp.getString(KEY_TTS_ENGINE, "")
end

function saveTtsEngine(pkgName)
  local sp = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
  local editor = sp.edit()
  editor.putString(KEY_TTS_ENGINE, pkgName)
  editor.apply()
end

function initTtsEngine(onReadyCallback)
  local selectedPkg = getSavedTtsEngine()
  
  if ttsEngine ~= nil then
    pcall(function()
      ttsEngine.stop()
      ttsEngine.shutdown()
    end)
    ttsEngine = nil
  end

  isTtsReady = false

  local initListener = luajava.createProxy("android.speech.tts.TextToSpeech$OnInitListener", {
    onInit = function(status)
      if status == TextToSpeech.SUCCESS and ttsEngine ~= nil then
        pcall(function()
          local result = ttsEngine.setLanguage(Locale("id", "ID"))
          if result == TextToSpeech.LANG_MISSING_DATA or result == TextToSpeech.LANG_NOT_SUPPORTED then
            ttsEngine.setLanguage(Locale.getDefault())
          end
        end)
        isTtsReady = true
      else
        isTtsReady = false
      end
      if onReadyCallback then onReadyCallback() end
    end
  })

  pcall(function()
    if selectedPkg ~= "" and selectedPkg ~= nil then
      ttsEngine = TextToSpeech(context, initListener, selectedPkg)
    else
      ttsEngine = TextToSpeech(context, initListener)
    end
  end)
end

function suaraNavigasi(teks)
  if isTtsReady and ttsEngine ~= nil then
    pcall(function()
      ttsEngine.speak(teks, TextToSpeech.QUEUE_FLUSH, nil, "NavID_" .. os.time())
    end)
  else
    pcall(function()
      service.speak(teks)
    end)
  end
end

function stopSuaraTts()
  pcall(function()
    if ttsEngine ~= nil then
      ttsEngine.stop()
    end
  end)
  pcall(function()
    service.stop()
  end)
end

function pilihEngineTtsDialog()
  local dummyTts = TextToSpeech(context, nil)
  local engines = dummyTts.getEngines()
  
  local engineList = {}
  local pkgList = {}
  
  if engines ~= nil then
    for i = 0, engines.size() - 1 do
      local eng = engines.get(i)
      table.insert(engineList, tostring(eng.label))
      table.insert(pkgList, tostring(eng.name))
    end
  end

  runOnUI(function()
    if #engineList == 0 then
      suaraNavigasi("Tidak ditemukan mesin TTS lain di HP Anda.")
      menuUtama()
      return
    end

    local builder = getDialogBuilder()
    builder.setTitle("Pilih Mesin Suara (TTS) Navigasi")
    builder.setItems(engineList, {
      onClick = function(dialog, which)
        local selectedPkg = pkgList[which + 1]
        saveTtsEngine(selectedPkg)
        initTtsEngine(function()
          suaraNavigasi("Suara navigasi berhasil diubah ke " .. engineList[which + 1])
        end)
        menuUtama()
      end
    })
    builder.setNegativeButton("Kembali", {
      onClick = function()
        menuUtama()
      end
    })

    local dlg = createOverlayDialog(builder)
    dlg.show()
  end)
end

-- ========================================================
-- PENYIMPANAN API KEY & BOOKMARK
-- ========================================================
function getSavedApiKey()
  local sp = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
  return sp.getString(KEY_API, "")
end

function saveApiKey(key)
  local sp = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
  local editor = sp.edit()
  editor.putString(KEY_API, key)
  editor.apply()
end

function getSavedBookmarks()
  local sp = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
  local rawJson = sp.getString(KEY_BOOKMARKS, "[]")
  local success, res = pcall(function() return json.decode(rawJson) end)
  if success and res and type(res) == "table" then
    return res
  end
  return {}
end

function saveBookmarksTable(tbl)
  local sp = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
  local editor = sp.edit()
  local success, rawJson = pcall(function() return json.encode(tbl) end)
  if success then
    editor.putString(KEY_BOOKMARKS, rawJson)
    editor.apply()
  end
end

function simpanLokasiBaru(nama, lat, lng, note)
  local list = getSavedBookmarks()
  local newItem = {
    name = nama,
    lat = lat,
    lng = lng,
    note = note or ""
  }
  table.insert(list, newItem)
  saveBookmarksTable(list)
  suaraNavigasi("Lokasi " .. nama .. " berhasil disimpan.")
  return newItem
end

function getDialogBuilder()
  local themeWrapper = luajava.bindClass("android.view.ContextThemeWrapper")(context, android.R.style.Theme_DeviceDefault_Dialog_Alert)
  return AlertDialog.Builder(themeWrapper)
end

function createOverlayDialog(builder)
  local dlg = builder.create()
  local window = dlg.getWindow()
  if window then
    window.setType(2038)
  end
  return dlg
end

function hitungJarakMeter(lat1, lon1, lat2, lon2)
  local R = 6371000
  local dLat = math.rad(lat2 - lat1)
  local dLon = math.rad(lon2 - lon1)
  local a = math.sin(dLat/2) * math.sin(dLat/2) +
            math.cos(math.rad(lat1)) * math.cos(math.rad(lat2)) *
            math.sin(dLon/2) * math.sin(dLon/2)
  local c = 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))
  return math.floor(R * c)
end

-- ========================================================
-- KONTROL NAVIGASI OTOMATIS & FITUR CEK SISA JARAK
-- ========================================================
function stopLocationUpdates()
  local lm = context.getSystemService(Context.LOCATION_SERVICE)
  if lm then
    pcall(function()
      if activeLocationListener then
        lm.removeUpdates(activeLocationListener)
      end
    end)
  end
  activeLocationListener = nil
end

function hentikanNavigasiOtomatis()
  setNavigasiAktifStatus(false, nil, nil)
  activeTargetItem = nil
  activeStartLoc = nil
  stopLocationUpdates()
  stopSuaraTts()
  suaraNavigasi("Navigasi dihentikan.")
  menuUtama()
end

function cekSisaJarakDanCatatan()
  local target = getActiveTargetItem()
  local startLoc = getActiveStartLoc()
  
  if target == nil then
    suaraNavigasi("Navigasi otomatis sedang tidak aktif.")
    menuUtama()
    return
  end

  suaraNavigasi("Mengecek jarak perjalanan...")

  local lm = context.getSystemService(Context.LOCATION_SERVICE)
  if not lm then 
    suaraNavigasi("Layanan lokasi tidak tersedia.")
    menuUtama()
    return 
  end

  local function prosesHitungDanUcapkan(lat, lng)
    local sisaJarak = hitungJarakMeter(lat, lng, target.lat, target.lng)
    local info = ""
    
    if startLoc and startLoc.lat and startLoc.lng and (startLoc.lat ~= 0 or startLoc.lng ~= 0) then
      local sudahDitempuh = hitungJarakMeter(startLoc.lat, startLoc.lng, lat, lng)
      info = "Anda sudah berjalan " .. sudahDitempuh .. " meter. Sisa jarak ke " .. target.name .. " adalah " .. sisaJarak .. " meter lagi."
    else
      info = "Sisa jarak ke " .. target.name .. " adalah " .. sisaJarak .. " meter lagi."
    end
    
    if target.note and target.note ~= "" then
      info = info .. " Catatan panduan: " .. target.note
    end

    suaraNavigasi(info)
    menuUtama()
  end

  local checkListener = nil
  checkListener = luajava.createProxy("android.location.LocationListener", {
    onLocationChanged = function(locObj)
      if locObj ~= nil then
        local realLoc = locObj
        if tostring(locObj):find("ArrayList") or (pcall(function() return locObj.get ~= nil end) and locObj.get) then
          pcall(function()
            if locObj.size() > 0 then realLoc = locObj.get(0) end
          end)
        end

        local success, lat, lng = pcall(function()
          return realLoc.getLatitude(), realLoc.getLongitude()
        end)

        if success and lat and lng then
          pcall(function() lm.removeUpdates(checkListener) end)
          prosesHitungDanUcapkan(lat, lng)
        end
      end
    end,
    onStatusChanged = function(provider, status, extras) end,
    onProviderEnabled = function(provider) end,
    onProviderDisabled = function(provider) end
  })

  pcall(function()
    lm.requestSingleUpdate(LocationManager.GPS_PROVIDER, checkListener, Looper.getMainLooper())
  end)
end

function mulaiNavigasiOtomatis(targetItem)
  activeTargetItem = targetItem

  local lm = context.getSystemService(Context.LOCATION_SERVICE)
  if not lm then return end

  local isGpsEnabled = lm.isProviderEnabled(LocationManager.GPS_PROVIDER)

  if not isGpsEnabled then
    suaraNavigasi("GPS belum aktif.")
    setNavigasiAktifStatus(false, nil, nil)
    activeTargetItem = nil
    menuUtama()
    return
  end

  local startLat, startLng = 0, 0
  activeStartLoc = { lat = startLat, lng = startLng }
  setNavigasiAktifStatus(true, targetItem, activeStartLoc)

  stopLocationUpdates()

  suaraNavigasi("Navigasi otomatis dimulai menuju " .. targetItem.name .. ".")

  local maxSudahDitempuh = 0
  local lastValidLat, lastValidLng = 0, 0
  
  -- JANGKAR UTAMA DENGAN SYARAT KETAT DI BAWAH 5 METER & TTS PENGUMUMAN JARAK
  local anchorLat, anchorLng = 0, 0
  local hasAnchor = false

  activeLocationListener = luajava.createProxy("android.location.LocationListener", {
    onLocationChanged = function(locObj)
      if getActiveTargetItem() == nil then
        stopLocationUpdates()
        stopSuaraTts()
        return
      end
      
      if locObj ~= nil then
        local realLoc = locObj
        if tostring(locObj):find("ArrayList") or (pcall(function() return locObj.get ~= nil end) and locObj.get) then
          pcall(function()
            if locObj.size() > 0 then realLoc = locObj.get(0) end
          end)
        end
        
        local success, provider, lat, lng, accuracy = pcall(function()
          return realLoc.getProvider(), realLoc.getLatitude(), realLoc.getLongitude(), realLoc.getAccuracy()
        end)
        
        -- SYARAT: GPS murni dan akurasi maksimal 3 meter
        if success and provider == LocationManager.GPS_PROVIDER and lat and lng and (not accuracy or accuracy <= 3) then
          
          -- Jika belum punya jangkar atau jangkar sebelumnya masih di atas 5 meter, uji kestabilannya dulu
          if not hasAnchor then
            if lastValidLat ~= 0 and lastValidLng ~= 0 then
              local jarakAwal = hitungJarakMeter(lastValidLat, lastValidLng, lat, lng)
              -- Baru dikunci sebagai jangkar mati jika pergeserannya sudah di bawah 5 meter (stabil)
              if jarakAwal < 5 then
                anchorLat, anchorLng = lat, lng
                hasAnchor = true
                
                -- TTS Menyebutkan jarak kestabilan secara real-time saat terkunci
                suaraNavigasi("Titik awal terkunci stabil pada jarak " .. jarakAwal .. " meter.")
              end
            else
              lastValidLat, lastValidLng = lat, lng
              return
            end
          end

          if not hasAnchor then
            lastValidLat, lastValidLng = lat, lng
            return
          end

          -- SETELAH JANGKAR DIBAWAH 5 METER TERKUNCI:
          local jarakDrift = hitungJarakMeter(lastValidLat, lastValidLng, lat, lng)
          
          if jarakDrift < 3 then
            return 
          end

          if jarakDrift > 30 then
            return
          end

          lastValidLat, lastValidLng = lat, lng
          local sisaJarak = hitungJarakMeter(lat, lng, targetItem.lat, targetItem.lng)
          
          if sisaJarak <= 4 then
            local pesanTiba = "Anda telah tiba di tujuan " .. targetItem.name
            if targetItem.note and targetItem.note ~= "" then
              pesanTiba = pesanTiba .. ". Catatan panduan: " .. targetItem.note
            end
            
            stopLocationUpdates()
            setNavigasiAktifStatus(false, nil, nil)
            activeTargetItem = nil
            activeStartLoc = nil
            stopSuaraTts()
            
            suaraNavigasi(pesanTiba)
          else
            local startLoc = getActiveStartLoc()
            local pesanProgres = ""
            
            if startLoc and startLoc.lat and startLoc.lng and (startLoc.lat ~= 0 or startLoc.lng ~= 0) then
              local hitungTemp = hitungJarakMeter(startLoc.lat, startLoc.lng, lat, lng)
              
              if hitungTemp > maxSudahDitempuh then
                maxSudahDitempuh = hitungTemp
              end
              
              pesanProgres = "Sudah berjalan " .. maxSudahDitempuh .. " meter. Sisa jarak ke " .. targetItem.name .. " adalah " .. sisaJarak .. " meter lagi."
            else
              pesanProgres = "Sisa jarak ke " .. targetItem.name .. " adalah " .. sisaJarak .. " meter lagi."
            end
            
            suaraNavigasi(pesanProgres)
          end
        end
      end
    end,
    onStatusChanged = function(provider, status, extras) end,
    onProviderEnabled = function(provider) end,
    onProviderDisabled = function(provider) end
  })

  pcall(function()
    lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000, 0.5, activeLocationListener, Looper.getMainLooper())
  end)
end

function bukaAplikasiNavigasi(lat, lng)
  local geoUri = Uri.parse("geo:" .. lat .. "," .. lng .. "?q=" .. lat .. "," .. lng)
  local mapIntent = Intent(Intent.ACTION_VIEW, geoUri)
  mapIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

  pcall(function()
    local chooser = Intent.createChooser(mapIntent, "Pilih Aplikasi Navigasi")
    chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    context.startActivity(chooser)
  end)
end

-- ========================================================
-- KUNCI LOKASI 100% PARABOLA (MENOLAK SEGALA JENIS BANTUAN)
-- ========================================================
function kunciLokasiSaatIni()
  suaraNavigasi("Mengaktifkan mode parabola satelit. Pastikan di bawah langit terbuka tanpa penghalang.")
  
  local lm = context.getSystemService(Context.LOCATION_SERVICE)
  if not lm then 
    suaraNavigasi("Layanan lokasi tidak tersedia.")
    menuUtama()
    return 
  end

  if not lm.isProviderEnabled(LocationManager.GPS_PROVIDER) then
    suaraNavigasi("GPS belum aktif.")
    menuUtama()
    return
  end

  local tempListener = nil
  local isLocked = false
  local timeoutHandler = Handler(Looper.getMainLooper())
  local timeoutRunnable = nil

  local sampleCount = 0
  local targetSamples = 8 
  local accumLat, accumLng = 0, 0
  local lastLat, lastLng = 0, 0

  tempListener = luajava.createProxy("android.location.LocationListener", {
    onLocationChanged = function(locObj)
      if isLocked then return end
      if locObj ~= nil then
        local realLoc = locObj
        if tostring(locObj):find("ArrayList") or (pcall(function() return locObj.get ~= nil end) and locObj.get) then
          pcall(function()
            if locObj.size() > 0 then realLoc = locObj.get(0) end
          end)
        end
        
        local success, provider, lat, lng, accuracy, timeLoc, extras = pcall(function()
          return realLoc.getProvider(), realLoc.getLatitude(), realLoc.getLongitude(), realLoc.getAccuracy(), realLoc.getTime(), realLoc.getExtras()
        end)
        
        if success and provider == LocationManager.GPS_PROVIDER and lat and lng then
          local currentTime = os.time() * 1000
          if timeLoc and (currentTime - timeLoc > 800) then
            return
          end

          local acc = accuracy or 99
          
          if acc <= 3 then
            local satCount = 0
            if extras then
              pcall(function()
                if extras.containsKey("satellites") then
                  satCount = extras.getInt("satellites")
                end
              end)
            end
            
            if satCount > 0 and satCount < 5 then
              return
            end

            if sampleCount == 0 then
              lastLat, lastLng = lat, lng
              accumLat = lat
              accumLng = lng
              sampleCount = 1
              suaraNavigasi("Sinyal satelit parabola mendeteksi celah terbuka, mengunci kestabilan...")
            else
              local selisihJarak = hitungJarakMeter(lastLat, lastLng, lat, lng)
              
              if selisihJarak <= 1.0 then
                sampleCount = sampleCount + 1
                accumLat = accumLat + lat
                accumLng = accumLng + lng
                lastLat, lastLng = lat, lng
                
                if sampleCount >= targetSamples then
                  isLocked = true
                  pcall(function() lm.removeUpdates(tempListener) end)
                  if timeoutRunnable then pcall(function() timeoutHandler.removeCallbacks(timeoutRunnable) end) end
                  
                  local finalLat = accumLat / targetSamples
                  local finalLng = accumLng / targetSamples
                  
                  local teksInfo = "Sinyal parabola terkunci sempurna! Akurasi " .. math.floor(acc) .. " meter."
                  pilihAksiLokasi(teksInfo, finalLat, finalLng, "Titik Berdiri Saya")
                end
              else
                sampleCount = 1
                accumLat = lat
                accumLng = lng
                lastLat, lastLng = lat, lng
              end
            end
          end
        end
      end
    end,
    onStatusChanged = function(provider, status, extras) end,
    onProviderEnabled = function(provider) end,
    onProviderDisabled = function(provider) end
  })

  pcall(function()
    lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 200, 0.01, tempListener, Looper.getMainLooper())
  end)

  timeoutRunnable = Runnable({
    run = function()
      if not isLocked then
        isLocked = true
        pcall(function() lm.removeUpdates(tempListener) end)
        suaraNavigasi("Gagal mengunci! Antena parabola terhalang atap atau berada di dalam ruangan.")
        menuUtama()
      end
    end
  })
  
  timeoutHandler.postDelayed(timeoutRunnable, 15000)
end

function cariLokasiAkurat()
  local apiKey = getSavedApiKey()
  if apiKey == "" then
    suaraNavigasi("Access Token LocationIQ belum diatur.")
    inputApiKeyDialog(function() dialogCariTeks() end)
  else
    dialogCariTeks()
  end
end

function dialogCariTeks()
  runOnUI(function()
    local builder = getDialogBuilder()
    builder.setTitle("Cari Lokasi di Sinjai")
    
    local input = EditText(context)
    input.setHint("Contoh: Jalan Anggrek / Masjid Agung")
    builder.setView(input)
    
    builder.setPositiveButton("Cari", {onClick=function()
      local query = tostring(input.getText()):match("^%s*(.-)%s*$")
      if query == "" then
        suaraNavigasi("Input lokasi tidak boleh kosong")
        menuUtama()
        return
      end
      
      -- OTOMATIS KUNCI WILAYAH: Jika user tidak mengetik kata "Sinjai", sistem otomatis tambah ", Sinjai"
      local queryLower = query:lower()
      if not queryLower:find("sinjai") then
        query = query .. ", Sinjai"
      end

      suaraNavigasi("Mencari lokasi di Sinjai...")
      prosesGeocodingNative(query)
    end})
    builder.setNeutralButton("Ubah Token", {onClick=function() inputApiKeyDialog(nil) end})
    builder.setNegativeButton("Kembali", {onClick=function() menuUtama() end})
    
    local dlg = createOverlayDialog(builder)
    dlg.show()
  end)
end

function prosesGeocodingNative(lokasi)
  Thread(Runnable({
    run = function()
      local apiKey = getSavedApiKey()
      local encodedQuery = Uri.encode(lokasi)
      local urlString = "https://us1.locationiq.com/v1/search?key=" .. apiKey .. "&q=" .. encodedQuery .. "&format=json&accept-language=id"
      
      local success, resultText = pcall(function()
        local url = URL(urlString)
        local conn = url.openConnection()
        conn.setRequestMethod("GET")
        conn.setConnectTimeout(8000)
        conn.setReadTimeout(8000)
        if conn.getResponseCode() == 200 then
          local inputStream = conn.getInputStream()
          local reader = BufferedReader(InputStreamReader(inputStream, "UTF-8"))
          local sb = {}
          local line = reader.readLine()
          while line ~= nil do
            table.insert(sb, line)
            line = reader.readLine()
          end
          reader.close()
          conn.disconnect()
          return table.concat(sb, "\n")
        else
          conn.disconnect()
          return "ERROR"
        end
      end)
      
      if success and resultText and resultText ~= "ERROR" then
        local parseSuccess, res = pcall(function() return json.decode(resultText) end)
        if parseSuccess and res and type(res) == "table" and #res > 0 then
          if #res == 1 then
            local item = res[1]
            pilihAksiLokasi("Lokasi ditemukan: " .. item.display_name, tonumber(item.lat), tonumber(item.lon), item.display_name)
          else
            pilihPilihanLokasiLocationIQ(res)
          end
        else
          suaraNavigasi("Lokasi tidak ditemukan di wilayah Sinjai.")
          menuUtama()
        end
      else
        suaraNavigasi("Gagal terhubung ke server lokasi.")
        menuUtama()
      end
    end
  })).start()
end

function pilihPilihanLokasiLocationIQ(results)
  runOnUI(function()
    local addresses = {}
    for i, item in ipairs(results) do
      table.insert(addresses, item.display_name)
    end
    
    local builder = getDialogBuilder()
    builder.setTitle("Pilih Lokasi Sesuai")
    builder.setItems(addresses, {
      onClick = function(dialog, which)
        local selected = results[which + 1]
        pilihAksiLokasi("Lokasi dipilih: " .. selected.display_name, tonumber(selected.lat), tonumber(selected.lon), selected.display_name)
      end
    })
    builder.setNegativeButton("Kembali", {onClick=function() menuUtama() end})
    
    local dlg = createOverlayDialog(builder)
    dlg.show()
  end)
end

function inputApiKeyDialog(onSuccessCallback)
  runOnUI(function()
    local currentKey = getSavedApiKey()
    local builder = getDialogBuilder()
    builder.setTitle("Access Token LocationIQ")
    builder.setMessage("Masukkan Access Token LocationIQ Anda:")
    
    local input = EditText(context)
    input.setHint("pk.xxxxxxxxxxxxxxxx")
    if currentKey ~= "" then input.setText(currentKey) end
    builder.setView(input)
    
    builder.setPositiveButton("Simpan", {onClick=function()
      local newKey = tostring(input.getText()):match("^%s*(.-)%s*$")
      if newKey == "" then
        suaraNavigasi("Access Token tidak boleh kosong")
      else
        saveApiKey(newKey)
        suaraNavigasi("Access Token berhasil disimpan")
        if onSuccessCallback then 
          onSuccessCallback() 
        else
          menuUtama()
        end
      end
    end})
    builder.setNegativeButton("Kembali", {onClick=function() menuUtama() end})
    
    local dlg = createOverlayDialog(builder)
    dlg.show()
  end)
end

function pilihAksiLokasi(pesanSuara, lat, lng, defaultNama)
  suaraNavigasi(pesanSuara)
  
  runOnUI(function()
    local options = {
      "▶ Langsung Navigasi Otomatis (10 Detik)",
      "🗺️ Buka Aplikasi Navigasi Lain (Google Maps/Lazarillo)",
      "💾 Simpan ke Bookmark Dulu"
    }

    local builder = getDialogBuilder()
    builder.setTitle("Hasil Pencarian Lokasi")
    
    builder.setItems(options, {
      onClick = function(dialog, which)
        if which == 0 then
          local tempItem = {
            name = defaultNama,
            lat = lat,
            lng = lng,
            note = ""
          }
          mulaiNavigasiOtomatis(tempItem)
        elseif which == 1 then
          bukaAplikasiNavigasi(lat, lng)
        elseif which == 2 then
          dialogSimpanNamaDanCatatan(defaultNama, lat, lng)
        end
      end
    })
    
    builder.setNegativeButton("Kembali", {onClick=function() menuUtama() end})
    
    local dlg = createOverlayDialog(builder)
    dlg.show()
  end)
end

function dialogSimpanNamaDanCatatan(defaultNama, lat, lng)
  runOnUI(function()
    local builder = getDialogBuilder()
    builder.setTitle("Simpan Bookmark Lokasi")
    
    local layout = LinearLayout(context)
    layout.setOrientation(LinearLayout.VERTICAL)
    layout.setPadding(30, 20, 30, 20)

    local txtNama = EditText(context)
    txtNama.setHint("Nama Penanda")
    txtNama.setText(defaultNama)
    layout.addView(txtNama)

    local txtNote = EditText(context)
    txtNote.setHint("Catatan Panduan (Misal: Pagar bambu)")
    layout.addView(txtNote)

    builder.setView(layout)
    
    builder.setPositiveButton("Simpan Saja", {
      onClick = function()
        local namaInput = tostring(txtNama.getText()):match("^%s*(.-)%s*$")
        local noteInput = tostring(txtNote.getText()):match("^%s*(.-)%s*$")
        if namaInput == "" then namaInput = "Lokasi Tanpa Nama" end
        
        simpanLokasiBaru(namaInput, lat, lng, noteInput)
        menuUtama()
      end
    })
    
    builder.setNeutralButton("Simpan & Navigasi", {
      onClick = function()
        local namaInput = tostring(txtNama.getText()):match("^%s*(.-)%s*$")
        local noteInput = tostring(txtNote.getText()):match("^%s*(.-)%s*$")
        if namaInput == "" then namaInput = "Lokasi Tanpa Nama" end
        
        local savedItem = simpanLokasiBaru(namaInput, lat, lng, noteInput)
        mulaiNavigasiOtomatis(savedItem)
      end
    })
    
    builder.setNegativeButton("Kembali", {onClick=function() menuUtama() end})
    
    local dlg = createOverlayDialog(builder)
    dlg.show()
  end)
end

function kelolaLokasiTersimpan()
  local list = getSavedBookmarks()
  if #list == 0 then
    suaraNavigasi("Belum ada lokasi yang tersimpan.")
    menuUtama()
    return
  end

  runOnUI(function()
    local items = {}
    for i, item in ipairs(list) do
      table.insert(items, item.name)
    end

    local builder = getDialogBuilder()
    builder.setTitle("Daftar Lokasi Tersimpan")
    builder.setItems(items, {
      onClick = function(dialog, which)
        local selectedIndex = which + 1
        local selectedItem = list[selectedIndex]
        menuAksiLokasiTersimpan(selectedItem, selectedIndex)
      end
    })
    builder.setNegativeButton("Kembali", {
      onClick = function()
        menuUtama()
      end
    })

    local dlg = createOverlayDialog(builder)
    dlg.show()
  end)
end

function menuAksiLokasiTersimpan(item, index)
  runOnUI(function()
    local options = {
      "▶️ Mulai Navigasi Otomatis",
      "🗺️ Buka Aplikasi Navigasi Lain (Google Maps/Lazarillo)",
      "✏ Edit Nama & Catatan Panduan",
      "🗑 Hapus Lokasi Ini"
    }

    local builder = getDialogBuilder()
    builder.setTitle(item.name)
    builder.setItems(options, {
      onClick = function(dialog, which)
        if which == 0 then
          mulaiNavigasiOtomatis(item)
        elseif which == 1 then
          bukaAplikasiNavigasi(item.lat, item.lng)
        elseif which == 2 then
          dialogEditNamaDanCatatan(item, index)
        elseif which == 3 then
          dialogKonfirmasiHapus(item, index)
        end
      end
    })
    builder.setNegativeButton("Kembali", {
      onClick = function()
        kelolaLokasiTersimpan()
      end
    })

    local dlg = createOverlayDialog(builder)
    dlg.show()
  end)
end

function dialogEditNamaDanCatatan(item, index)
  runOnUI(function()
    local builder = getDialogBuilder()
    builder.setTitle("Edit Bookmark")
    
    local layout = LinearLayout(context)
    layout.setOrientation(LinearLayout.VERTICAL)
    layout.setPadding(30, 20, 30, 20)

    local txtNama = EditText(context)
    txtNama.setText(item.name)
    layout.addView(txtNama)

    local txtNote = EditText(context)
    txtNote.setText(item.note or "")
    txtNote.setHint("Catatan Panduan (Misal: Pagar bambu)")
    layout.addView(txtNote)

    builder.setView(layout)

    builder.setPositiveButton("Simpan", {
      onClick = function()
        local newName = tostring(txtNama.getText()):match("^%s*(.-)%s*$")
        local newNote = tostring(txtNote.getText()):match("^%s*(.-)%s*$")
        if newName ~= "" then
          local list = getSavedBookmarks()
          if list[index] then
            list[index].name = newName
            list[index].note = newNote
            saveBookmarksTable(list)
            suaraNavigasi("Bookmark berhasil diperbarui.")
          end
        end
        kelolaLokasiTersimpan()
      end
    })
    builder.setNegativeButton("Batal", {
      onClick = function()
        kelolaLokasiTersimpan()
      end
    })

    local dlg = createOverlayDialog(builder)
    dlg.show()
  end)
end

function dialogKonfirmasiHapus(item, index)
  runOnUI(function()
    local builder = getDialogBuilder()
    builder.setTitle("Hapus Lokasi")
    builder.setMessage("Apakah Anda yakin ingin menghapus " .. item.name .. "?")

    builder.setPositiveButton("Hapus", {
      onClick = function()
        local list = getSavedBookmarks()
        table.remove(list, index)
        saveBookmarksTable(list)
        suaraNavigasi("Lokasi " .. item.name .. " berhasil dihapus.")
        kelolaLokasiTersimpan()
      end
    })
    builder.setNegativeButton("Batal", {
      onClick = function()
        kelolaLokasiTersimpan()
      end
    })

    local dlg = createOverlayDialog(builder)
    dlg.show()
  end)
end

function menuUtama()
  runOnUI(function()
    local menuOptions = {
      "📍 Kunci Lokasi & Mulai Navigasi Otomatis",
      "🔍 Cari Lokasi di Sinjai (LocationIQ)",
      "📏 Cek Sisa Jarak & Catatan Panduan",
      "💾 Kelola Lokasi Tersimpan",
      "🗣️ Pilih Mesin Suara (TTS) Navigasi",
      "🔑 Pengaturan Access Token LocationIQ",
      "⏹️ Hentikan Navigasi Otomatis"
    }

    local builder = getDialogBuilder()
    builder.setTitle("Menu Navigasi Otomatis")
    builder.setItems(menuOptions, {
      onClick = function(dialog, which)
        if which == 0 then
          kunciLokasiSaatIni()
        elseif which == 1 then
          cariLokasiAkurat()
        elseif which == 2 then
          cekSisaJarakDanCatatan()
        elseif which == 3 then
          kelolaLokasiTersimpan()
        elseif which == 4 then
          pilihEngineTtsDialog()
        elseif which == 5 then
          inputApiKeyDialog(nil)
        elseif which == 6 then
          hentikanNavigasiOtomatis()
        end
      end
    })
    builder.setNegativeButton("Tutup", nil)
    
    local dlg = createOverlayDialog(builder)
    dlg.show()
  end)
end

initTtsEngine(nil)
menuUtama()
