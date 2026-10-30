import { useState } from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import FadeIn from './effects/FadeIn'
import GradientText from './effects/GradientText'
import './Screenshots.css'

const screenshots = [
    {
        src: '/screenshots/Screenshot_20260101_024726.png',
        alt: 'Home Screen',
        title: 'Home Screen',
        description: 'Recently played, quick-access playlists, and your full library at a glance.'
    },
    {
        src: '/screenshots/Screenshot_20260101_024746.png',
        alt: 'Now Playing',
        title: 'Now Playing',
        description: 'Full-featured player with gorgeous album art, progress control, and queue management.'
    },
    {
        src: '/screenshots/Screenshot_20260101_024751.png',
        alt: 'Synced Lyrics',
        title: 'Synced Lyrics',
        description: 'Time-synced lyrics with blur and glow effects. Desktop fullscreen mode included.'
    },
    {
        src: '/screenshots/Screenshot_20260101_024803.png',
        alt: 'Login Screen',
        title: 'Server Setup',
        description: 'Connect to your Navidrome or any Subsonic-compatible server in seconds.'
    }
]

export default function Screenshots() {
    const [active, setActive] = useState(1)

    const prev = () => setActive(i => (i - 1 + screenshots.length) % screenshots.length)
    const next = () => setActive(i => (i + 1) % screenshots.length)

    return (
        <section id="screenshots" className="screenshots section">
            <div className="container">
                {/* Header */}
                <FadeIn className="ss-header">
                    <span className="section-tag">Screenshots</span>
                    <h2 className="ss-title">
                        See <GradientText>KumaFlow</GradientText> in Action
                    </h2>
                    <p className="ss-subtitle">
                        A beautiful, intuitive interface that makes streaming your music a joy.
                    </p>
                </FadeIn>

                {/* Phone showcase */}
                <FadeIn delay={0.15}>
                    <div className="ss-stage">
                        {/* Glow */}
                        <div className="ss-glow" />

                        {/* Phones */}
                        <div className="ss-phones">
                            {screenshots.map((s, i) => {
                                const offset = i - active
                                const isActive = i === active
                                const isAdjacent = Math.abs(offset) === 1
                                const isHidden = Math.abs(offset) > 1

                                return (
                                    <motion.button
                                        key={s.src}
                                        className={`ss-phone ${isActive ? 'ss-phone--active' : ''} ${isAdjacent ? 'ss-phone--adjacent' : ''}`}
                                        onClick={() => setActive(i)}
                                        animate={{
                                            x: `${offset * 105}%`,
                                            scale: isActive ? 1 : isAdjacent ? 0.8 : 0.65,
                                            opacity: isHidden ? 0 : isAdjacent ? 0.5 : 1,
                                            zIndex: isActive ? 10 : isAdjacent ? 5 : 1,
                                            rotateY: offset * -10,
                                        }}
                                        transition={{ type: 'spring', stiffness: 260, damping: 28 }}
                                        style={{ pointerEvents: isHidden ? 'none' : 'auto' }}
                                    >
                                        <div className="ss-phone-frame">
                                            <div className="ss-phone-notch" />
                                            <img src={s.src} alt={s.alt} className="ss-phone-img" />
                                        </div>
                                        {isActive && <div className="ss-phone-glow-ring" />}
                                    </motion.button>
                                )
                            })}
                        </div>

                        {/* Nav arrows */}
                        <button className="ss-nav ss-nav--prev" onClick={prev} aria-label="Previous">
                            <ChevronLeft size={22} />
                        </button>
                        <button className="ss-nav ss-nav--next" onClick={next} aria-label="Next">
                            <ChevronRight size={22} />
                        </button>
                    </div>
                </FadeIn>

                {/* Caption */}
                <AnimatePresence mode="wait">
                    <motion.div
                        key={active}
                        className="ss-caption"
                        initial={{ opacity: 0, y: 16 }}
                        animate={{ opacity: 1, y: 0 }}
                        exit={{ opacity: 0, y: -10 }}
                        transition={{ duration: 0.3 }}
                    >
                        <h3 className="ss-caption-title">{screenshots[active].title}</h3>
                        <p className="ss-caption-desc">{screenshots[active].description}</p>
                    </motion.div>
                </AnimatePresence>

                {/* Dots */}
                <div className="ss-dots">
                    {screenshots.map((_, i) => (
                        <button
                            key={i}
                            className={`ss-dot ${i === active ? 'ss-dot--active' : ''}`}
                            onClick={() => setActive(i)}
                            aria-label={`Screenshot ${i + 1}`}
                        />
                    ))}
                </div>
            </div>
        </section>
    )
}
