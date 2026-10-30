import { useState, useEffect } from 'react'
import Navbar from './components/Navbar'
import Hero from './components/Hero'
import Features from './components/Features'
import Screenshots from './components/Screenshots'
import DownloadSection from './components/Download'
import Community from './components/Community'
import Footer from './components/Footer'
import PrivacyPolicy from './components/PrivacyPolicy'
import AnimatedBackground from './components/effects/AnimatedBackground'
import './App.css'

function App() {
  const [showPrivacy, setShowPrivacy] = useState(false)

  // Check URL path on mount for direct /privacy access
  useEffect(() => {
    // Check if we have a saved path from 404.html redirect
    const savedPath = sessionStorage.getItem('spa_path')
    if (savedPath) {
      sessionStorage.removeItem('spa_path')
      if (savedPath === '/privacy') {
        setShowPrivacy(true)
        // Update URL to match without page reload
        window.history.replaceState(null, '', '/privacy')
        return
      }
    }

    // Direct access check
    if (window.location.pathname === '/privacy') {
      setShowPrivacy(true)
    }
  }, [])

  const handlePrivacyClick = (e) => {
    if (e) e.preventDefault()
    setShowPrivacy(true)
    window.history.pushState(null, '', '/privacy')
  }

  const handleBackToHome = () => {
    setShowPrivacy(false)
    window.history.pushState(null, '', '/')
  }

  if (showPrivacy) {
    return (
      <div className="app">
        <AnimatedBackground />
        <PrivacyPolicy onBack={handleBackToHome} />
      </div>
    )
  }

  return (
    <div className="app">
      <AnimatedBackground />
      <Navbar onPrivacyClick={handlePrivacyClick} />
      <main>
        <Hero />
        <Features />
        <Screenshots />
        <DownloadSection />
        <Community />
      </main>
      <Footer onPrivacyClick={handlePrivacyClick} />
    </div>
  )
}

export default App
