import { motion } from 'framer-motion'
import { MessageCircle, Github, Heart } from 'lucide-react'
import FadeIn from './effects/FadeIn'
import GradientText from './effects/GradientText'
import './Community.css'

const cryptoAddresses = [
    { network: 'Bitcoin (BTC)', address: 'bc1qrfv880kc8qamanalc5kcqs9q5wszh90e5eggyz' },
    { network: 'Solana (SOL)', address: 'E3JUcjyR6UCJtppU24iDrq82FyPeV9nhL1PKHx57iPXu' },
    { network: 'ETH / Monad / Hype', address: '0x01195b0Ae97b2D461aB0C746663bFE915eb9ac7c' },
]

const cards = [
    {
        icon: MessageCircle,
        color: '#5865f2',
        label: 'Discord',
        title: 'Join the Community',
        description: 'Chat with other KumaFlow users, get support, share tips, and stay up to date on new features.',
        actions: [
            { href: 'https://discord.gg/k9FqpbT65M', label: 'Join Discord', style: 'discord' }
        ]
    },
    {
        icon: Heart,
        color: '#ff2d55',
        label: 'Support',
        title: 'Support Development',
        description: 'KumaFlow is free and open source. If you enjoy it, consider supporting the developer with crypto.',
        actions: [],
        crypto: true,
    },
    {
        icon: Github,
        color: '#ffffff',
        label: 'Open Source',
        title: 'Contribute on GitHub',
        description: 'Report bugs, suggest features, submit pull requests, and shape the future of KumaFlow.',
        actions: [
            { href: 'https://github.com/kumaflow/KumaFlow', label: 'View on GitHub', style: 'github' }
        ]
    },
]

export default function Community() {
    return (
        <section className="community section">
            <div className="container">
                {/* Header */}
                <FadeIn className="com-header">
                    <span className="section-tag">Community</span>
                    <h2 className="com-title">
                        Join the <GradientText>KumaFlow</GradientText> Community
                    </h2>
                    <p className="com-subtitle">
                        Connect with other users, support the project, and help shape its future.
                    </p>
                </FadeIn>

                {/* Cards */}
                <div className="com-grid">
                    {cards.map((card, i) => (
                        <FadeIn key={card.label} delay={0.1 * i}>
                            <div className="com-card">
                                <div
                                    className="com-card-icon"
                                    style={{ background: `${card.color}18`, color: card.color }}
                                >
                                    <card.icon size={24} />
                                </div>
                                <span className="com-card-label" style={{ color: card.color }}>
                                    {card.label}
                                </span>
                                <h3 className="com-card-title">{card.title}</h3>
                                <p className="com-card-desc">{card.description}</p>

                                {card.crypto && (
                                    <div className="com-crypto">
                                        <table className="com-crypto-table">
                                            <thead>
                                                <tr>
                                                    <th>Network</th>
                                                    <th>Address</th>
                                                </tr>
                                            </thead>
                                            <tbody>
                                                {cryptoAddresses.map(({ network, address }) => (
                                                    <tr key={network}>
                                                        <td className="com-crypto-network">{network}</td>
                                                        <td><code className="com-crypto-addr">{address}</code></td>
                                                    </tr>
                                                ))}
                                            </tbody>
                                        </table>
                                    </div>
                                )}

                                {card.actions.length > 0 && (
                                    <div className="com-card-actions">
                                        {card.actions.map(action => (
                                            <motion.a
                                                key={action.href}
                                                href={action.href}
                                                target="_blank"
                                                rel="noopener noreferrer"
                                                className={`btn com-btn com-btn--${action.style}`}
                                                whileHover={{ scale: 1.03 }}
                                                whileTap={{ scale: 0.97 }}
                                            >
                                                {action.style === 'discord' && <MessageCircle size={16} />}
                                                {action.style === 'github' && <Github size={16} />}
                                                {action.label}
                                            </motion.a>
                                        ))}
                                    </div>
                                )}
                            </div>
                        </FadeIn>
                    ))}
                </div>
            </div>
        </section>
    )
}
