import { motion } from 'framer-motion'

export default function AnimatedBackground() {
    return (
        <div style={{
            position: 'fixed',
            inset: 0,
            zIndex: -1,
            overflow: 'hidden',
            background: '#080808',
            pointerEvents: 'none',
        }}>
            {/* Top-right hero orb */}
            <motion.div
                style={{
                    position: 'absolute',
                    top: '-15%',
                    right: '-5%',
                    width: 'min(70vw, 900px)',
                    height: 'min(70vw, 900px)',
                    borderRadius: '50%',
                    background: 'radial-gradient(circle, rgba(255,45,85,0.22) 0%, transparent 68%)',
                    filter: 'blur(70px)',
                }}
                animate={{ scale: [1, 1.08, 1], x: [0, 25, 0], y: [0, 18, 0] }}
                transition={{ duration: 9, repeat: Infinity, ease: 'easeInOut' }}
            />
            {/* Bottom-left orb */}
            <motion.div
                style={{
                    position: 'absolute',
                    bottom: '5%',
                    left: '-8%',
                    width: 'min(55vw, 700px)',
                    height: 'min(55vw, 700px)',
                    borderRadius: '50%',
                    background: 'radial-gradient(circle, rgba(255,45,85,0.14) 0%, transparent 68%)',
                    filter: 'blur(90px)',
                }}
                animate={{ scale: [1, 1.12, 1], x: [0, -18, 0], y: [0, -24, 0] }}
                transition={{ duration: 11, repeat: Infinity, ease: 'easeInOut', delay: 1.5 }}
            />
            {/* Center accent */}
            <motion.div
                style={{
                    position: 'absolute',
                    top: '40%',
                    left: '35%',
                    width: 'min(45vw, 550px)',
                    height: 'min(45vw, 550px)',
                    borderRadius: '50%',
                    background: 'radial-gradient(circle, rgba(255,100,120,0.08) 0%, transparent 70%)',
                    filter: 'blur(100px)',
                }}
                animate={{ scale: [1, 1.15, 1], x: [0, 30, 0], y: [0, -20, 0] }}
                transition={{ duration: 13, repeat: Infinity, ease: 'easeInOut', delay: 3 }}
            />
            {/* Subtle grid noise overlay */}
            <div style={{
                position: 'absolute',
                inset: 0,
                backgroundImage: `radial-gradient(rgba(255,255,255,0.018) 1px, transparent 1px)`,
                backgroundSize: '40px 40px',
                opacity: 0.5,
            }} />
        </div>
    )
}
