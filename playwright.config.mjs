import {defineConfig} from '@playwright/test';
export default defineConfig({
  testDir:'./web/ui-tests',fullyParallel:false,workers:1,timeout:30000,
  use:{baseURL:'http://127.0.0.1:4173',viewport:{width:1280,height:850},screenshot:'only-on-failure'},
  webServer:{command:'python3 -m http.server 4173 --bind 127.0.0.1 --directory Sources/MDRApp/Resources/Web',url:'http://127.0.0.1:4173',reuseExistingServer:true}
});
