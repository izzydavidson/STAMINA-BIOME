// Playwright test for modal UI and log streaming
const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({ headless: false });
  const context = await browser.newContext();
  const page = await context.newPage();

  try {
    console.log('🌐 Navigating to app...');
    await page.goto('http://127.0.0.1:9000', { waitUntil: 'networkidle', timeout: 10000 });
    await page.waitForTimeout(2000);

    console.log('📝 Going to Short Read tab...');
    await page.click('text=Short Read');
    await page.waitForTimeout(1000);

    console.log('⚙️  Configuring pipeline...');

    // Set run name
    const runNameInput = await page.locator('input[id*="run_name"]').first();
    await runNameInput.fill('Playwright_Modal_Test');

    // Browse for input file - set the hidden input directly
    const testFilePath = process.env.TEST_FASTQ || require('path').resolve(__dirname, '../main/data/test_inputs/ERR10233589_1.fastq');

    await page.evaluate((path) => {
      // Find all input fields with input_path in their ID
      const inputs = document.querySelectorAll('input[id*="input_path"]');
      inputs.forEach(input => {
        // Set both display and hidden inputs
        input.value = path;
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
      });
    }, testFilePath);

    await page.waitForTimeout(1000);

    console.log('✅ Checking validation...');
    const validationText = await page.locator('.alert').first().textContent();
    console.log('   Validation:', validationText);

    if (!validationText.includes('valid')) {
      console.log('❌ Configuration not valid:', validationText);
      await browser.close();
      process.exit(1);
    }

    console.log('▶️  Clicking Run Pipeline...');
    await page.click('button:has-text("Run Pipeline")');
    await page.waitForTimeout(2000);

    console.log('🔍 Checking for modal...');

    // Check if modal appeared
    const modalVisible = await page.locator('.modal-dialog').isVisible();
    if (!modalVisible) {
      console.log('❌ Modal did not appear!');
      await browser.close();
      process.exit(1);
    }
    console.log('✅ Modal appeared!');

    // Check modal is full screen
    const modalStyles = await page.evaluate(() => {
      const modal = document.querySelector('.modal-dialog');
      const computed = window.getComputedStyle(modal);
      return {
        width: computed.width,
        height: computed.height,
        maxWidth: computed.maxWidth
      };
    });
    console.log('📐 Modal dimensions:', modalStyles);

    // Check for status badge
    const statusBadge = await page.locator('.badge').first().textContent();
    console.log('🏷️  Status badge:', statusBadge);

    if (!statusBadge.includes('PROGRESS') && !statusBadge.includes('COMPLETE') && !statusBadge.includes('FAILED')) {
      console.log('❌ Status badge not showing correctly');
    } else {
      console.log('✅ Status badge showing');
    }

    // Check for elapsed time
    await page.waitForTimeout(2000);
    const elapsedTime = await page.evaluate(() => {
      const timeEl = document.querySelector('strong');
      return timeEl ? timeEl.textContent : null;
    });
    console.log('⏱️  Elapsed time:', elapsedTime);

    // Check for config display
    const configVisible = await page.locator('pre').first().isVisible();
    if (configVisible) {
      const configText = await page.locator('pre').first().textContent();
      console.log('📄 Config visible:', configText.substring(0, 100) + '...');
      if (configText.includes('Playwright_Modal_Test')) {
        console.log('✅ Config contains run name');
      }
    }

    // Check for logs
    console.log('📜 Waiting for logs to appear...');
    await page.waitForTimeout(5000);

    const logContainer = await page.locator('div[id*="log"]').last();
    const logContent = await logContainer.textContent();

    console.log('📋 Log content length:', logContent.length);
    console.log('📋 First 500 chars of logs:');
    console.log(logContent.substring(0, 500));

    // Check for expected log patterns
    const hasDispatch = logContent.includes('[dispatch]') || logContent.includes('dispatch');
    const hasContainer = logContent.includes('[container]') || logContent.includes('container');
    const hasConfig = logContent.includes('[config]') || logContent.includes('config');
    const hasInfo = logContent.includes('[INFO]');

    console.log('\n📊 Log content checks:');
    console.log('   [INFO] messages:', hasInfo ? '✅' : '❌');
    console.log('   [dispatch] messages:', hasDispatch ? '✅' : '❌');
    console.log('   [container] messages:', hasContainer ? '✅' : '❌');
    console.log('   [config] messages:', hasConfig ? '✅' : '❌');

    if (!hasInfo && !hasDispatch && !hasContainer) {
      console.log('\n❌ FAIL: No pipeline logs found in UI!');
      console.log('Full log content:', logContent);
    } else {
      console.log('\n✅ SUCCESS: Pipeline logs are streaming to UI!');
    }

    // Check for buttons
    const cancelBtn = await page.locator('button:has-text("Cancel")').isVisible();
    const returnBtn = await page.locator('button:has-text("Return")').isVisible();

    console.log('\n🔘 Buttons:');
    console.log('   Cancel button:', cancelBtn ? '✅' : '❌');
    console.log('   Return button:', returnBtn ? '✅' : '❌');

    console.log('\n⏳ Waiting 15 seconds to observe pipeline progress...');
    for (let i = 0; i < 15; i++) {
      await page.waitForTimeout(1000);
      const currentLogs = await logContainer.textContent();
      const currentStatus = await page.locator('.badge').first().textContent();
      console.log(`   [${i+1}s] Logs: ${currentLogs.length} chars, Status: ${currentStatus.trim()}`);
    }

    console.log('\n✅ Test complete! Modal is working.');
    console.log('Keeping browser open for 30 seconds for manual inspection...');
    await page.waitForTimeout(30000);

  } catch (error) {
    console.error('❌ Error during test:', error);
  } finally {
    await browser.close();
  }
})();
