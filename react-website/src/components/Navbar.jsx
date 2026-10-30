import { useState, useEffect } from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import { Menu, X, Github } from 'lucide-react'
import logo from '../assets/logo.png'
import './Navbar.css'

export default function Navbar() {
    const [isScrolled, setIsScrolled] = useState(false)
    const [isMobileMenuOpen, setIsMobileMenuOpen] = useState(false)

    useEffect(() => {
        const handleScroll = () => setIsScrolled(window.scrollY > 30)
        window.addEventListener('scroll', handleScroll, { passive: true })
        return () => window.removeEventListener('scroll', handleScroll)
    }, [])

    const navLinks = [
        { name: 'Features', href: '#features' },
        { name: 'Screenshots', href: '#screenshots' },
        { name: 'Download', href: '#download' },
    ]

    return (
        <>
            <motion.nav
                className={`navbar ${isScrolled ? 'navbar--scrolled' : ''}`}
                initial={{ y: -80, opacity: 0 }}
                animate={{ y: 0, opacity: 1 }}
                transition={{ duration: 0.7, ease: [0.22, 1, 0.36, 1] }}
            >
                <div className="navbar-inner container">
                    {/* Logo */}
                    <a href="#" className="navbar-logo">
                        <img src={logo} alt="KumaFlow" className="navbar-logo-img" />
                        <span className="navbar-logo-text">KumaFlow</span>
                    </a>

                    {/* Desktop links */}
                    <nav className="navbar-links">
                        {navLinks.map((link) => (
                            <a key={link.name} href={link.href} className="navbar-link">
                                {link.name}
                            </a>
                        ))}
                    </nav>

                    {/* Desktop actions */}
                    <div className="navbar-actions">
                        <a
                            href="https://github.com/kumaflow/KumaFlow"
                            target="_blank"
                            rel="noopener noreferrer"
                            className="navbar-gh"
                            aria-label="GitHub"
                        >
                            <Github size={18} />
                            <span>GitHub</span>
                        </a>
                        <a href="#download" className="btn btn-primary navbar-cta">
                            Download
                        </a>
                    </div>

                    {/* Mobile toggle */}
                    <button
                        className="navbar-toggle"
                        onClick={() => setIsMobileMenuOpen(!isMobileMenuOpen)}
                        aria-label="Toggle menu"
                    >
                        {isMobileMenuOpen ? <X size={22} /> : <Menu size={22} />}
                    </button>
                </div>
            </motion.nav>

            {/* Mobile menu */}
            <AnimatePresence>
                {isMobileMenuOpen && (
                    <motion.div
                        className="navbar-mobile"
                        initial={{ opacity: 0, y: -8 }}
                        animate={{ opacity: 1, y: 0 }}
                        exit={{ opacity: 0, y: -8 }}
                        transition={{ duration: 0.22 }}
                    >
                        {navLinks.map((link, i) => (
                            <motion.a
                                key={link.name}
                                href={link.href}
                                className="navbar-mobile-link"
                                initial={{ opacity: 0, x: -12 }}
                                animate={{ opacity: 1, x: 0 }}
                                transition={{ delay: i * 0.06 }}
                                onClick={() => setIsMobileMenuOpen(false)}
                            >
                                {link.name}
                            </motion.a>
                        ))}
                        <a
                            href="https://github.com/kumaflow/KumaFlow"
                            target="_blank"
                            rel="noopener noreferrer"
                            className="navbar-mobile-link"
                            onClick={() => setIsMobileMenuOpen(false)}
                        >
                            <Github size={17} /> GitHub
                        </a>
                        <a
                            href="#download"
                            className="btn btn-primary"
                            style={{ marginTop: 8 }}
                            onClick={() => setIsMobileMenuOpen(false)}
                        >
                            Download Free
                        </a>
                    </motion.div>
                )}
            </AnimatePresence>
        </>
    )
}
